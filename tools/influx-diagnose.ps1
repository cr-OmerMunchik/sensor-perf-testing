<#
.SYNOPSIS
    Diagnoses InfluxDB connectivity and schema. Run on MON VM when influx-analyze returns empty data.

.DESCRIPTION
    Runs discovery queries to list buckets, measurements, and sample data.
    Helps identify wrong bucket/org, field naming, or missing host/scenario tags.

.PARAMETER Token
    InfluxDB API token. Uses $env:INFLUXDB_TOKEN if not provided.

.PARAMETER InfluxUrl
    InfluxDB base URL (default: http://localhost:8086 when on MON VM).

.PARAMETER TimeRange
    Flux time range (default: -7d). Use -30d if tests were older.
#>

[CmdletBinding()]
param(
    [string]$Token = $env:INFLUXDB_TOKEN,
    [string]$InfluxUrl = "http://localhost:8086",
    [string]$TimeRange = "-7d"
)

$ErrorActionPreference = "Stop"

if (-not $Token) {
    Write-Error "InfluxDB token required. Set `$env:INFLUXDB_TOKEN or pass -Token."
}

$queryUrl = "$InfluxUrl/api/v2/query?org=activeprobe-perf"
$headers = @{
    "Authorization" = "Token $Token"
    "Accept"        = "application/csv"
    "Content-Type"  = "application/vnd.flux"
}

function Invoke-InfluxQuery {
    param([string]$Query, [string]$Label = "Query")
    try {
        $response = Invoke-WebRequest -Uri $queryUrl -Method Post -Headers $headers -Body $Query -ContentType "application/vnd.flux" -UseBasicParsing
        return $response.Content
    } catch {
        Write-Host "  FAILED: $_" -ForegroundColor Red
        return $null
    }
}

Write-Host "`n=== InfluxDB Diagnostic (org=activeprobe-perf) ===" -ForegroundColor Cyan
Write-Host "URL: $InfluxUrl | TimeRange: $TimeRange`n" -ForegroundColor Gray

# 1. List buckets
Write-Host "[1] Buckets in org:" -ForegroundColor Yellow
$bucketsQuery = 'buckets()'
$buckets = Invoke-InfluxQuery -Query $bucketsQuery
if ($buckets) {
    $buckets -split "`n" | Where-Object { $_ -match "telegraf|_monitoring|_tasks" } | ForEach-Object { Write-Host "    $_" }
}

# 2. What _measurement values exist? (sample from any data)
Write-Host "`n[2] Distinct _measurement values in 'telegraf' bucket:" -ForegroundColor Yellow
$measQuery = @"
from(bucket: "telegraf")
  |> range(start: $TimeRange)
  |> distinct(column: "_measurement")
  |> limit(n: 30)
"@
$meas = Invoke-InfluxQuery -Query $measQuery
if ($meas) {
    $meas -split "`n" | Where-Object { $_ -notmatch "^#" -and $_ -match "_measurement|win_|sensor" } | ForEach-Object { Write-Host "    $_" }
}

# 3. Sample: any data at all in last 7d?
Write-Host "`n[3] Sample rows (any measurement, last 5 points):" -ForegroundColor Yellow
$sampleQuery = @"
from(bucket: "telegraf")
  |> range(start: $TimeRange)
  |> limit(n: 5)
"@
$sample = Invoke-InfluxQuery -Query $sampleQuery
if ($sample) {
    $lines = $sample -split "`n" | Where-Object { $_ -notmatch "^#" }
    $lines | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
    if ($lines.Count -eq 0 -or ($lines | Where-Object { $_ -match "_measurement|_field|_value" }).Count -eq 0) {
        Write-Host "    (no data - try -TimeRange -30d if tests were older)" -ForegroundColor Red
    }
} else {
    Write-Host "    No response - check org name and token" -ForegroundColor Red
}

# 4. Check win_cpu specifically
Write-Host "`n[4] win_cpu measurement - fields and tags:" -ForegroundColor Yellow
$winCpuQuery = @"
from(bucket: "telegraf")
  |> range(start: $TimeRange)
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> limit(n: 3)
"@
$winCpu = Invoke-InfluxQuery -Query $winCpuQuery
if ($winCpu) {
    $header = ($winCpu -split "`n" | Where-Object { $_ -match "result,table" } | Select-Object -First 1)
    if ($header) { Write-Host "    Columns: $header" }
    $winCpu -split "`n" | Where-Object { $_ -notmatch "^#" -and $_ -match "win_cpu" } | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" }
} else {
    Write-Host "    No win_cpu data" -ForegroundColor Red
}

# 5. Check sensor_process
Write-Host "`n[5] sensor_process measurement:" -ForegroundColor Yellow
$sensorQuery = @"
from(bucket: "telegraf")
  |> range(start: $TimeRange)
  |> filter(fn: (r) => r._measurement == "sensor_process")
  |> limit(n: 3)
"@
$sensor = Invoke-InfluxQuery -Query $sensorQuery
if ($sensor) {
    $sensor -split "`n" | Where-Object { $_ -notmatch "^#" -and $_ -match "sensor_process" } | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" }
} else {
    Write-Host "    No sensor_process data (expected on no-sensor VM)" -ForegroundColor Yellow
}

# 6. Distinct host and scenario tags (from win_cpu)
Write-Host "`n[6] Distinct 'host' and 'scenario' tag values:" -ForegroundColor Yellow
$hostQuery = @"
from(bucket: "telegraf")
  |> range(start: $TimeRange)
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> distinct(column: "host")
  |> limit(n: 20)
"@
$hosts = Invoke-InfluxQuery -Query $hostQuery
if ($hosts) {
    $hosts -split "`n" | Where-Object { $_ -notmatch "^#" -and $_ -match "host|TEST|test|_value" } | ForEach-Object { Write-Host "    $_" }
}

Write-Host "`n=== Done. Fix influx-analyze.ps1 if bucket/measurement/field names differ. ===" -ForegroundColor Cyan
