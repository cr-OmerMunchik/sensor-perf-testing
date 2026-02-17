#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs InfluxDB v2.8.0 on the MON VM and registers it as a Windows service.

.DESCRIPTION
    Downloads InfluxDB, extracts it, registers it as a Windows Scheduled Task
    (auto-start at boot), and starts it. After running this script, open
    http://localhost:8086 to complete the initial setup wizard.

    This script is idempotent -- safe to run again after a partial failure.

.NOTES
    Run this script on the MON VM.
#>

$ErrorActionPreference = "Stop"

$influxVersion = "2.8.0"
$influxUrl = "https://download.influxdata.com/influxdb/releases/v$influxVersion/influxdb2-$influxVersion-windows_amd64.zip"
$installDir = "C:\InfluxData\influxdb"
$dataDir = "C:\InfluxData\influxdb-data"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " InfluxDB v$influxVersion Installation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ---------- Step 1: Create directories ----------
Write-Host "`n[1/6] Creating directories..." -ForegroundColor White
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

# ---------- Step 2: Download InfluxDB (skip if influxd.exe already present) ----------
if (Test-Path "$installDir\influxd.exe") {
    Write-Host "[2/6] influxd.exe already exists, skipping download." -ForegroundColor Yellow
}
else {
    $zipPath = "$env:TEMP\influxdb2.zip"

    if (Test-Path $zipPath) {
        Write-Host "[2/6] Using previously downloaded ZIP..." -ForegroundColor Yellow
    }
    else {
        Write-Host "[2/6] Downloading InfluxDB v$influxVersion..." -ForegroundColor White
        Invoke-WebRequest -Uri $influxUrl -OutFile $zipPath -UseBasicParsing
        Write-Host "      Downloaded to $zipPath" -ForegroundColor Gray
    }

    # ---------- Step 3: Extract ----------
    Write-Host "[3/6] Extracting..." -ForegroundColor White
    $extractDir = "$env:TEMP\influxdb-extract"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive $zipPath -DestinationPath $extractDir -Force

    # Find influxd.exe in the extracted archive and copy from its directory
    $influxdExe = Get-ChildItem $extractDir -Recurse -Filter "influxd.exe" | Select-Object -First 1
    if (-not $influxdExe) {
        Write-Error "influxd.exe not found in the extracted archive. Check the download."
        exit 1
    }

    Write-Host "      Found influxd.exe at: $($influxdExe.DirectoryName)" -ForegroundColor Gray
    Get-ChildItem $influxdExe.DirectoryName -File | Copy-Item -Destination $installDir -Force
    Write-Host "      Extracted to $installDir" -ForegroundColor Gray

    # Cleanup
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Verify influxd.exe exists
if (-not (Test-Path "$installDir\influxd.exe")) {
    Write-Error "influxd.exe not found at $installDir\influxd.exe after extraction."
    exit 1
}
Write-Host "      [OK] influxd.exe present." -ForegroundColor Green

# ---------- Step 4: Add to PATH ----------
Write-Host "[4/6] Adding to system PATH..." -ForegroundColor White
$currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($currentPath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$installDir", "Machine")
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    Write-Host "      Added $installDir to PATH" -ForegroundColor Gray
}
else {
    Write-Host "      Already in PATH" -ForegroundColor Gray
}

# ---------- Step 5: Register InfluxDB as a scheduled task (auto-start) ----------
Write-Host "[5/6] Registering InfluxDB as a scheduled task..." -ForegroundColor White

# Clean up broken service from previous attempt
$existingService = Get-Service -Name "influxdb" -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "      Removing broken service from previous attempt..." -ForegroundColor Yellow
    Stop-Service influxdb -Force -ErrorAction SilentlyContinue
    & sc.exe delete influxdb 2>&1 | Out-Null
    Start-Sleep -Seconds 2
}

# Remove existing scheduled task if present (idempotent)
$existingTask = Get-ScheduledTask -TaskName "InfluxDB" -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "      Removing existing scheduled task..." -ForegroundColor Yellow
    Stop-ScheduledTask -TaskName "InfluxDB" -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "InfluxDB" -Confirm:$false
}

# Also stop any running influxd process
Stop-Process -Name "influxd" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$action = New-ScheduledTaskAction -Execute "$installDir\influxd.exe" -WorkingDirectory $installDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365)

Register-ScheduledTask -TaskName "InfluxDB" `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "InfluxDB v2 Time Series Database for Performance Testing" | Out-Null

Write-Host "      Scheduled task registered." -ForegroundColor Gray

# ---------- Step 6: Start InfluxDB ----------
Write-Host "[6/6] Starting InfluxDB..." -ForegroundColor White
Start-ScheduledTask -TaskName "InfluxDB"
Start-Sleep -Seconds 5

$influxProc = Get-Process -Name "influxd" -ErrorAction SilentlyContinue
if ($influxProc) {
    Write-Host "`n[OK] InfluxDB is running! (PID: $($influxProc.Id))" -ForegroundColor Green
}
else {
    Write-Host "`n[ERROR] InfluxDB failed to start." -ForegroundColor Red
    Write-Host "  Try running manually: & '$installDir\influxd.exe'" -ForegroundColor Yellow
    exit 1
}

# ---------- Summary ----------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " InfluxDB Installation Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step: Open http://localhost:8086 in your browser" -ForegroundColor Yellow
Write-Host "and complete the initial setup:" -ForegroundColor Yellow
Write-Host "  Username     : admin" -ForegroundColor White
Write-Host "  Password     : (choose a strong password)" -ForegroundColor White
Write-Host "  Organization : activeprobe-perf" -ForegroundColor White
Write-Host "  Bucket       : telegraf" -ForegroundColor White
Write-Host ""
Write-Host "After setup, create an API token:" -ForegroundColor Yellow
Write-Host "  1. Go to Load Data > API Tokens" -ForegroundColor White
Write-Host "  2. Generate API Token > All Access API Token" -ForegroundColor White
Write-Host "  3. Name it 'telegraf-writer'" -ForegroundColor White
Write-Host "  4. COPY AND SAVE the token!" -ForegroundColor White
