<#
.SYNOPSIS
    SSH to MON VM, run influx-analyze, and SCP the result back.
    Requires: INFLUXDB_TOKEN env var, SSH key to admin@172.46.16.24
#>
param([string]$MonHost = "172.46.16.24", [string]$SshUser = "admin")

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir = Split-Path -Parent $scriptDir

if (-not $env:INFLUXDB_TOKEN) {
    Write-Error "Set INFLUXDB_TOKEN first: `$env:INFLUXDB_TOKEN = 'your-token'"
}

$remoteDir = "C:/temp"
$remoteScript = "$remoteDir/influx-analyze.ps1"
$remoteJson = "$remoteDir/influx-data.json"

Write-Host "Copying influx-analyze.ps1 to MON VM..." -ForegroundColor Cyan
scp -o ConnectTimeout=10 "$scriptDir\influx-analyze.ps1" "${SshUser}@${MonHost}:$remoteScript" | Out-Null

Write-Host "Running influx-analyze on MON VM (this may take 30-60 sec)..." -ForegroundColor Cyan
$token = $env:INFLUXDB_TOKEN -replace "'", "''"
$runScript = @"
`$env:INFLUXDB_TOKEN='$token'
& 'C:/temp/influx-analyze.ps1' -InfluxUrl http://localhost:8086 -OutputPath 'C:/temp/influx-data.json' -DebugDumpCsv
"@
$runScript | Out-File -FilePath "$env:TEMP\run-influx.ps1" -Encoding utf8
scp "$env:TEMP\run-influx.ps1" "${SshUser}@${MonHost}:C:/temp/run-influx.ps1" | Out-Null
ssh "${SshUser}@${MonHost}" "powershell -NoProfile -ExecutionPolicy Bypass -File C:/temp/run-influx.ps1" 2>&1 | ForEach-Object { Write-Host "  $_" }

Write-Host "Copying influx-data.json back..." -ForegroundColor Cyan
scp "${SshUser}@${MonHost}:$remoteJson" (Join-Path $toolsDir "influx-data-fresh.json") | Out-Null

Write-Host "Done. influx-data-fresh.json updated." -ForegroundColor Green
Write-Host "Re-run: .\tools\generate-executive-summary.ps1 -InfluxJsonPath .\influx-data-fresh.json -Scenario user_account_modify" -ForegroundColor Yellow
