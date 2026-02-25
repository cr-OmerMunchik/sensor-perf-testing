#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Repairs InfluxDB after accidental move of C:\InfluxData to C:\res\InfluxData.

.DESCRIPTION
    Run this on MON VM if you accidentally moved InfluxData with "mv infl* res".
    Stops InfluxDB, restores C:\InfluxData from C:\res\InfluxData, restarts InfluxDB.

.NOTES
    Run on MON VM as Administrator.
#>

$ErrorActionPreference = "Stop"

Write-Host "`n=== InfluxDB Path Repair ===" -ForegroundColor Cyan

# 1. Stop InfluxDB
Write-Host "`n[1] Stopping InfluxDB..." -ForegroundColor White
Stop-ScheduledTask -TaskName "InfluxDB" -ErrorAction SilentlyContinue
Stop-Process -Name "influxd" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# 2. Ensure C:\InfluxData exists
if (-not (Test-Path "C:\InfluxData")) {
    New-Item -ItemType Directory -Path "C:\InfluxData" -Force | Out-Null
    Write-Host "    Created C:\InfluxData" -ForegroundColor Gray
}

# 3. Restore influxdb-data (the actual database)
if (Test-Path "C:\res\InfluxData\influxdb-data") {
    if (-not (Test-Path "C:\InfluxData\influxdb-data")) {
        Move-Item -Path "C:\res\InfluxData\influxdb-data" -Destination "C:\InfluxData\" -Force
        Write-Host "[2] Restored influxdb-data to C:\InfluxData\" -ForegroundColor Green
    } else {
        Write-Host "[2] C:\InfluxData\influxdb-data already exists, skipping" -ForegroundColor Yellow
    }
} else {
    Write-Host "[2] C:\res\InfluxData\influxdb-data not found" -ForegroundColor Yellow
}

# 4. Restore influxdb binaries
if (Test-Path "C:\res\InfluxData\influxdb") {
    if (-not (Test-Path "C:\InfluxData\influxdb\influxd.exe")) {
        if (-not (Test-Path "C:\InfluxData\influxdb")) {
            New-Item -ItemType Directory -Path "C:\InfluxData\influxdb" -Force | Out-Null
        }
        Copy-Item -Path "C:\res\InfluxData\influxdb\*" -Destination "C:\InfluxData\influxdb\" -Recurse -Force
        Write-Host "[3] Restored influxdb binaries to C:\InfluxData\influxdb\" -ForegroundColor Green
    } else {
        Write-Host "[3] C:\InfluxData\influxdb\influxd.exe already exists" -ForegroundColor Gray
    }
}

# 5. Remove stray C:\res\InfluxData
if (Test-Path "C:\res\InfluxData") {
    Remove-Item "C:\res\InfluxData" -Recurse -Force
    Write-Host "[4] Removed C:\res\InfluxData" -ForegroundColor Green
}

# 6. Move influx-data.json back to C:\ if it's in res
if (Test-Path "C:\res\influx-data.json") {
    Move-Item -Path "C:\res\influx-data.json" -Destination "C:\" -Force
    Write-Host "[5] Moved influx-data.json to C:\" -ForegroundColor Green
}

# 7. Start InfluxDB
Write-Host "`n[6] Starting InfluxDB..." -ForegroundColor White
Start-ScheduledTask -TaskName "InfluxDB"
Start-Sleep -Seconds 5

$proc = Get-Process -Name "influxd" -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host "`n[OK] InfluxDB is running (PID: $($proc.Id))" -ForegroundColor Green
} else {
    Write-Host "`n[ERROR] InfluxDB did not start. Check Event Viewer or run manually: C:\InfluxData\influxdb\influxd.exe" -ForegroundColor Red
    exit 1
}

Write-Host "`n=== Repair complete ===" -ForegroundColor Cyan
