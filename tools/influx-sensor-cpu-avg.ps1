<#
.SYNOPSIS
    Fetches sensor process CPU (avg + peak) from InfluxDB for the slide table.
    Output: normalized % of total system (÷ 8 cores).
    Uses influx-analyze.ps1 (which now correctly sums across processes before avg/peak).

.EXAMPLE
    $env:INFLUXDB_TOKEN = "your-token"
    .\influx-sensor-cpu-avg.ps1
    .\influx-sensor-cpu-avg.ps1 -InfluxUrl http://172.46.16.24:8086 -TimeRange "-14d"

    # If workstation can't reach InfluxDB, run on MON VM:
    .\run-influx-on-mon.ps1
    # Then run this with -InfluxJsonPath .\influx-data-fresh.json
#>
param(
    [string]$Token = $env:INFLUXDB_TOKEN,
    [string]$InfluxUrl = "http://172.46.16.24:8086",
    [string]$TimeRange = "-14d",
    [int]$NumCores = 8,
    [string]$InfluxJsonPath  # Use pre-fetched JSON (e.g. from run-influx-on-mon)
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($InfluxJsonPath -and (Test-Path $InfluxJsonPath)) {
    $json = Get-Content $InfluxJsonPath -Raw | ConvertFrom-Json
} else {
    if (-not $Token) { Write-Error "Set INFLUXDB_TOKEN or pass -Token, or use -InfluxJsonPath with pre-fetched JSON" }
    $tempJson = Join-Path $env:TEMP "influx-sensor-avg-$(Get-Date -Format 'yyyyMMddHHmmss').json"
    & "$scriptDir\influx-analyze.ps1" -Token $Token -InfluxUrl $InfluxUrl -TimeRange $TimeRange -OutputPath $tempJson | Out-Null
    if (-not (Test-Path $tempJson)) { Write-Error "influx-analyze failed" }
    $json = Get-Content $tempJson -Raw | ConvertFrom-Json
    Remove-Item $tempJson -Force -ErrorAction SilentlyContinue
}

$sensorCpu = $json.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-3" }
$scenarios = @("combined_high_density", "user_account_modify", "soak_test")

Write-Host "`n=== Sensor processes CPU (normalized to % of total system, num_cores=$NumCores) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "| Scenario | Avg CPU | Peak CPU |"
Write-Host "|----------|---------|----------|"

foreach ($sc in $scenarios) {
    $row = $sensorCpu | Where-Object { $_.scenario -eq $sc } | Select-Object -First 1
    $avgRaw = if ($row -and $null -ne $row.avgCpu) { $row.avgCpu } else { $null }
    $peakRaw = if ($row -and $null -ne $row.peakCpu) { $row.peakCpu } else { $null }
    $avgNorm = if ($avgRaw -ne $null -and $avgRaw -ge 0) { [math]::Round($avgRaw / $NumCores, 1).ToString() + "%" } else { "N/A" }
    $peakNorm = if ($peakRaw -ne $null -and $peakRaw -ge 0) { [math]::Round($peakRaw / $NumCores, 1).ToString() + "%" } else { "N/A" }
    Write-Host "| $sc | $avgNorm | $peakNorm |"
}

Write-Host ""
Write-Host "Copy the table above into your slide." -ForegroundColor Yellow
