# Run influx-check-recent.ps1 on MON VM via SSH
param([string]$MonHost = "172.46.16.24", [string]$SshUser = "admin")

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $env:INFLUXDB_TOKEN) {
    Write-Error "Set INFLUXDB_TOKEN first"
}

$token = $env:INFLUXDB_TOKEN -replace "'", "''"
$runScript = @"
`$env:INFLUXDB_TOKEN='$token'
& 'C:/temp/influx-check-recent.ps1' -InfluxUrl http://localhost:8086
"@
$runScript | Out-File -FilePath "$env:TEMP\influx-check-run.ps1" -Encoding utf8
scp -o StrictHostKeyChecking=no "$env:TEMP\influx-check-run.ps1" "${SshUser}@${MonHost}:C:/temp/check.ps1" | Out-Null
scp -o StrictHostKeyChecking=no "$scriptDir\influx-check-recent.ps1" "${SshUser}@${MonHost}:C:/temp/influx-check-recent.ps1" | Out-Null
ssh -o StrictHostKeyChecking=no "${SshUser}@${MonHost}" "powershell -NoProfile -ExecutionPolicy Bypass -File C:/temp/check.ps1"
