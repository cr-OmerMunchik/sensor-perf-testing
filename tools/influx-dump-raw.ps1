<#
.SYNOPSIS
    Dumps raw InfluxDB CSV for win_cpu and win_mem to diagnose parsing issues.
    Run on MON VM or with InfluxUrl pointing to MON.
#>
param(
    [string]$Token = $env:INFLUXDB_TOKEN,
    [string]$InfluxUrl = "http://172.46.16.24:8086",
    [string]$TimeRange = "-7d",
    [string]$OutDir = "."
)

$ErrorActionPreference = "Stop"
if (-not $Token) { Write-Error "INFLUXDB_TOKEN required" }

$queryUrl = "$InfluxUrl/api/v2/query?org=activeprobe-perf"
$headers = @{ "Authorization" = "Token $Token"; "Accept" = "application/csv"; "Content-Type" = "application/vnd.flux" }

$sysCpuQ = "from(bucket: `"telegraf`") |> range(start: $TimeRange) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> filter(fn: (r) => r.instance == `"_Total`") |> group(columns: [`"host`", `"scenario`"]) |> mean() |> group() |> yield(name: `"sys`")"
$sysMemQ = "from(bucket: `"telegraf`") |> range(start: $TimeRange) |> filter(fn: (r) => r._measurement == `"win_mem`") |> filter(fn: (r) => r._field == `"Available_MBytes`") |> group(columns: [`"host`", `"scenario`"]) |> mean() |> group() |> yield(name: `"avail`")"

Write-Host "Fetching win_cpu mean()..." -ForegroundColor Cyan
$cpuRaw = Invoke-WebRequest -Uri $queryUrl -Method Post -Headers $headers -Body $sysCpuQ -ContentType "application/vnd.flux" -UseBasicParsing
$cpuPath = Join-Path $OutDir "influx-raw-win_cpu.csv"
$cpuRaw.Content | Set-Content $cpuPath -Encoding UTF8
Write-Host "  Saved to $cpuPath" -ForegroundColor Green
$cpuRaw.Content -split "`n" | Where-Object { $_ -notmatch "^#" } | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" }

Write-Host "`nFetching win_mem mean()..." -ForegroundColor Cyan
$memRaw = Invoke-WebRequest -Uri $queryUrl -Method Post -Headers $headers -Body $sysMemQ -ContentType "application/vnd.flux" -UseBasicParsing
$memPath = Join-Path $OutDir "influx-raw-win_mem.csv"
$memRaw.Content | Set-Content $memPath -Encoding UTF8
Write-Host "  Saved to $memPath" -ForegroundColor Green
$memRaw.Content -split "`n" | Where-Object { $_ -notmatch "^#" } | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" }
