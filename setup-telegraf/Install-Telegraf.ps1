#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Telegraf on a test VM and registers it as a Windows service.

.DESCRIPTION
    Downloads Telegraf, extracts it, deploys the telegraf.conf configuration
    file with the correct settings for this VM, and registers Telegraf as
    a Windows service.

.PARAMETER MonVmIp
    IP address of the MON VM running InfluxDB (e.g., 172.46.16.24).

.PARAMETER InfluxToken
    The InfluxDB API token created during MON VM setup.

.PARAMETER SensorInstalled
    Whether the ActiveProbe sensor is installed on this VM. "yes" or "no".

.PARAMETER SensorVersion
    The sensor version string (e.g., "24.1.0"). Leave empty if no sensor.

.PARAMETER MachineProfile
    The hardware profile tag (e.g., "enterprise_4vcpu_16gb").

.PARAMETER OsVersion
    The OS version tag (e.g., "win11_26200").

.EXAMPLE
    # On BASELINE VM (no sensor):
    .\Install-Telegraf.ps1 -InfluxToken "your-token-here" -SensorInstalled "no"

    # On SENSOR VM (with sensor):
    .\Install-Telegraf.ps1 -InfluxToken "your-token-here" -SensorInstalled "yes" -SensorVersion "24.1.0"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$MonVmIp,

    [Parameter(Mandatory = $true)]
    [string]$InfluxToken,

    [Parameter(Mandatory = $true)]
    [ValidateSet("yes", "no")]
    [string]$SensorInstalled,

    [string]$SensorVersion = "",
    [string]$MachineProfile = "large_8vcpu_16gb",
    [string]$OsVersion = "win11_26200"
)

$ErrorActionPreference = "Stop"

$telegrafVersion = "1.37.2"
$telegrafUrl = "https://dl.influxdata.com/telegraf/releases/telegraf-${telegrafVersion}_windows_amd64.zip"
$installDir = "C:\InfluxData\telegraf"
$confPath = "$installDir\telegraf.conf"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Telegraf v$telegrafVersion Installation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  MON VM IP        : $MonVmIp" -ForegroundColor White
Write-Host "  Sensor Installed : $SensorInstalled" -ForegroundColor White
Write-Host "  Sensor Version   : $(if ($SensorVersion) { $SensorVersion } else { '(none)' })" -ForegroundColor White
Write-Host "  Machine Profile  : $MachineProfile" -ForegroundColor White
Write-Host "  OS Version       : $OsVersion" -ForegroundColor White

# ---------- Step 1: Create directory ----------
Write-Host "`n[1/5] Creating directory..." -ForegroundColor White
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

# ---------- Step 2 & 3: Download and Extract ----------
if (Test-Path "$installDir\telegraf.exe") {
    Write-Host "[2/5] telegraf.exe already exists, skipping download." -ForegroundColor Yellow
    Write-Host "[3/5] Already extracted, skipping." -ForegroundColor Yellow
}
else {
    $zipPath = "$env:TEMP\telegraf.zip"
    if (Test-Path $zipPath) {
        Write-Host "[2/5] Using previously downloaded ZIP..." -ForegroundColor Yellow
    }
    else {
        Write-Host "[2/5] Downloading Telegraf v$telegrafVersion..." -ForegroundColor White
        Invoke-WebRequest -Uri $telegrafUrl -OutFile $zipPath -UseBasicParsing
        Write-Host "      Downloaded to $zipPath" -ForegroundColor Gray
    }

    Write-Host "[3/5] Extracting..." -ForegroundColor White
    $extractDir = "$env:TEMP\telegraf-extract"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive $zipPath -DestinationPath $extractDir -Force

    # Find telegraf.exe in the extracted archive and copy from its directory
    $telegrafExe = Get-ChildItem $extractDir -Recurse -Filter "telegraf.exe" | Select-Object -First 1
    if (-not $telegrafExe) {
        Write-Error "telegraf.exe not found in the extracted archive."
        exit 1
    }
    Write-Host "      Found telegraf.exe at: $($telegrafExe.DirectoryName)" -ForegroundColor Gray
    Get-ChildItem $telegrafExe.DirectoryName -File | Copy-Item -Destination $installDir -Force
    Write-Host "      Extracted to $installDir" -ForegroundColor Gray

    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- Step 4: Deploy configuration ----------
Write-Host "[4/5] Deploying telegraf.conf..." -ForegroundColor White

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$templatePath = Join-Path $scriptDir "telegraf.conf"

if (Test-Path $templatePath) {
    $config = Get-Content $templatePath -Raw
}
else {
    Write-Error "telegraf.conf template not found at $templatePath. Make sure it's in the same directory as this script."
    exit 1
}

$config = $config -replace 'MON_VM_IP', $MonVmIp
$config = $config -replace 'INFLUXDB_TOKEN', $InfluxToken
$config = $config -replace '  sensor_installed = "no"', "  sensor_installed = `"$SensorInstalled`""
$config = $config -replace '  sensor_version = ""', "  sensor_version = `"$SensorVersion`""
$config = $config -replace '  machine_profile = "large_8vcpu_16gb"', "  machine_profile = `"$MachineProfile`""
$config = $config -replace '  os_version = "win11_26200"', "  os_version = `"$OsVersion`""

Set-Content -Path $confPath -Value $config -Encoding UTF8
Write-Host "      Configuration written to $confPath" -ForegroundColor Gray

# ---------- Step 5: Test and install service ----------
Write-Host "[5/5] Testing configuration and installing service..." -ForegroundColor White

Write-Host "      Testing connectivity to InfluxDB at ${MonVmIp}:8086..." -ForegroundColor Gray
$connTest = Test-NetConnection -ComputerName $MonVmIp -Port 8086 -WarningAction SilentlyContinue
if (-not $connTest.TcpTestSucceeded) {
    Write-Host "      [WARN] Cannot reach InfluxDB at ${MonVmIp}:8086." -ForegroundColor Yellow
    Write-Host "      Make sure MON VM is running and firewall is configured." -ForegroundColor Yellow
    Write-Host "      Continuing with installation anyway..." -ForegroundColor Yellow
}
else {
    Write-Host "      [OK] InfluxDB is reachable." -ForegroundColor Green
}

# Uninstall existing service if present
$existingService = Get-Service -Name "telegraf" -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "      Stopping and removing existing Telegraf service..." -ForegroundColor Yellow
    Stop-Service telegraf -Force -ErrorAction SilentlyContinue
    & "$installDir\telegraf.exe" --service uninstall
    Start-Sleep -Seconds 2
}

# Install as service
& "$installDir\telegraf.exe" --service install --config $confPath

# Start the service
Start-Service telegraf
Start-Sleep -Seconds 3

$svc = Get-Service telegraf
if ($svc.Status -eq "Running") {
    Write-Host "`n[OK] Telegraf is running!" -ForegroundColor Green
}
else {
    Write-Host "`n[ERROR] Telegraf failed to start." -ForegroundColor Red
    Write-Host "  Check Windows Event Viewer > Application > Source: telegraf" -ForegroundColor Red
    exit 1
}

# ---------- Summary ----------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Telegraf Installation Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Telegraf is collecting metrics every 10 seconds." -ForegroundColor White
Write-Host "Verify data flow:" -ForegroundColor Yellow
Write-Host "  1. Open http://${MonVmIp}:8086 (InfluxDB UI)" -ForegroundColor White
Write-Host "  2. Go to Data Explorer" -ForegroundColor White
Write-Host "  3. Select bucket 'telegraf', measurement 'win_cpu'" -ForegroundColor White
Write-Host "  4. You should see data points from this host." -ForegroundColor White
Write-Host ""
Write-Host "Useful commands:" -ForegroundColor Yellow
Write-Host "  Get-Service telegraf              # Check status" -ForegroundColor Gray
Write-Host "  Restart-Service telegraf           # Restart after config change" -ForegroundColor Gray
Write-Host "  & '$installDir\telegraf.exe' --config '$confPath' --test   # Test collection" -ForegroundColor Gray
