<#
.SYNOPSIS
    Installs Cybereason sensor with Phoenix backend parameters.

.DESCRIPTION
    Performs a silent installation of the sensor EXE with Phoenix-specific
    command-line parameters (DISCOVERY_SERVER_URL, ORGANIZATION_ID,
    PHOENIX_AUTH_INSTALLATION_KEY). Waits for sensor services to start
    and verifies they are running.

    Can also be called with -WaitOnly to skip installation and just
    wait for services to come up (useful after a separate install step).

    Can uninstall with -Uninstall flag.

.PARAMETER SensorExePath
    Full path to the sensor installer EXE.

.PARAMETER DiscoveryServerUrl
    Phoenix discovery server URL.

.PARAMETER OrganizationId
    Phoenix organization ID.

.PARAMETER PhoenixAuthKey
    Phoenix authentication installation key.

.PARAMETER WaitOnly
    Skip installation, only wait for sensor services to start.

.PARAMETER Uninstall
    Uninstall the sensor instead of installing.

.PARAMETER TimeoutSeconds
    Max seconds to wait for sensor services to start. Default: 300.

.EXAMPLE
    .\Install-Sensor-Phoenix.ps1 -SensorExePath C:\Temp\CybereasonSensor64.exe `
        -PhoenixAuthKey "3KZGZN5R1ZWY06NFGSD5XBFBSMJ4N5FQT8Q6V44XZ1EDNVF4BD2"

.EXAMPLE
    .\Install-Sensor-Phoenix.ps1 -SensorExePath C:\Temp\CybereasonSensor64.exe -Uninstall
#>
param(
    [Parameter(Mandatory = $false)]
    [string]$SensorExePath,

    [string]$DiscoveryServerUrl = "https://sensor-discovery-service-dev-us-ashburn-1.cybereason.net",

    [string]$OrganizationId = "1002",

    [Parameter(Mandatory = $false)]
    [string]$PhoenixAuthKey,

    [switch]$WaitOnly,

    [switch]$Uninstall,

    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

function Wait-SensorServices {
    param([int]$Timeout = 300)

    $targetProcesses = @("minionhost", "ActiveConsole")
    $elapsed = 0

    Write-Host "[INFO] Waiting for sensor processes: $($targetProcesses -join ', ')"
    while ($elapsed -lt $Timeout) {
        $running = Get-Process -Name $targetProcesses -ErrorAction SilentlyContinue
        $runningNames = @($running.ProcessName | Sort-Object -Unique)

        if ($runningNames.Count -ge $targetProcesses.Count) {
            Write-Host "[OK] All sensor processes running after ${elapsed}s" -ForegroundColor Green
            Get-Service *Cybereason* -ErrorAction SilentlyContinue | Format-Table Name, Status -AutoSize
            return $true
        }

        Start-Sleep -Seconds 10
        $elapsed += 10
        $missing = $targetProcesses | Where-Object { $_ -notin $runningNames }
        Write-Host "  Waiting ($elapsed/${Timeout}s) -- Running: [$($runningNames -join ', ')] Missing: [$($missing -join ', ')]"
    }

    Write-Host "[ERROR] Timed out waiting for sensor processes after ${Timeout}s" -ForegroundColor Red
    return $false
}

if ($WaitOnly) {
    Write-Host "=== Wait-Only Mode ===" -ForegroundColor Cyan
    $ok = Wait-SensorServices -Timeout $TimeoutSeconds
    if (-not $ok) { exit 1 }
    exit 0
}

if (-not $SensorExePath) {
    Write-Host "[ERROR] -SensorExePath is required" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $SensorExePath)) {
    Write-Host "[ERROR] Sensor EXE not found: $SensorExePath" -ForegroundColor Red
    exit 1
}

if ($Uninstall) {
    Write-Host "=== Uninstalling Sensor ===" -ForegroundColor Yellow
    Write-Host "[INFO] Running: $SensorExePath /uninstall /quiet"

    $taskName = "SensorUninstall_$(Get-Random)"
    $action = New-ScheduledTaskAction -Execute $SensorExePath -Argument "/uninstall /quiet"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName

    $taskTimeout = 120
    $taskElapsed = 0
    while ($taskElapsed -lt $taskTimeout) {
        Start-Sleep -Seconds 5
        $taskElapsed += 5
        $taskState = (Get-ScheduledTask -TaskName $taskName).State
        if ($taskState -ne "Running") { break }
    }
    $lastResult = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[INFO] Uninstall exit code: $lastResult"

    $elapsed = 0
    while ($elapsed -lt 120) {
        $remaining = Get-Service *Cybereason* -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
        if (-not $remaining) {
            Write-Host "[OK] All services stopped after ${elapsed}s" -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }

    if ($lastResult -ne 0) { exit 1 }
    exit 0
}

if (-not $PhoenixAuthKey) {
    Write-Host "[ERROR] -PhoenixAuthKey is required for installation" -ForegroundColor Red
    exit 1
}

Write-Host "=== Installing Sensor with Phoenix Parameters ===" -ForegroundColor Yellow
Write-Host "  Sensor EXE      : $SensorExePath"
Write-Host "  Discovery URL   : $DiscoveryServerUrl"
Write-Host "  Organization ID : $OrganizationId"
Write-Host "  Auth Key         : $($PhoenixAuthKey.Substring(0, 8))..."

$existingProcs = Get-Process minionhost, ActiveConsole -ErrorAction SilentlyContinue
if ($existingProcs) {
    Write-Host "[WARN] Sensor processes already running. Uninstalling first..." -ForegroundColor Yellow
    $unTaskName = "SensorPreUninstall_$(Get-Random)"
    $unAction = New-ScheduledTaskAction -Execute $SensorExePath -Argument "/uninstall /quiet"
    $unPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $unTaskName -Action $unAction -Principal $unPrincipal -Force | Out-Null
    Start-ScheduledTask -TaskName $unTaskName
    $unElapsed = 0
    while ($unElapsed -lt 120) {
        Start-Sleep -Seconds 5
        $unElapsed += 5
        if ((Get-ScheduledTask -TaskName $unTaskName).State -ne "Running") { break }
    }
    Unregister-ScheduledTask -TaskName $unTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}

$installArgs = "DISCOVERY_SERVER_URL=$DiscoveryServerUrl ORGANIZATION_ID=$OrganizationId PHOENIX_AUTH_INSTALLATION_KEY=$PhoenixAuthKey /quiet"
Write-Host "[INFO] Running: $SensorExePath $installArgs"

$wrapperScript = "C:\Temp\run_sensor_install.cmd"
$logFile = "C:\Temp\sensor_install.log"
Set-Content -Path $wrapperScript -Value "@echo off`r`n`"$SensorExePath`" $installArgs > `"$logFile`" 2>&1`r`necho EXIT_CODE=%ERRORLEVEL% >> `"$logFile`""

$taskName = "SensorInstall_$(Get-Random)"
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$wrapperScript`""
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

$taskTimeout = 120
$taskElapsed = 0
while ($taskElapsed -lt $taskTimeout) {
    Start-Sleep -Seconds 5
    $taskElapsed += 5
    $taskState = (Get-ScheduledTask -TaskName $taskName).State
    if ($taskState -ne "Running") { break }
    Write-Host "  Installer running ($taskElapsed/${taskTimeout}s)..."
}

$lastResult = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "[INFO] Install exit code (via scheduled task): $lastResult"

if (Test-Path $logFile) {
    Write-Host "[INFO] Installer log output:"
    Get-Content $logFile | ForEach-Object { Write-Host "  $_" }
}

if ($lastResult -ne 0) {
    Write-Host "[WARN] Sensor installer returned exit code $lastResult -- waiting for services anyway" -ForegroundColor Yellow
}

$ok = Wait-SensorServices -Timeout $TimeoutSeconds
if (-not $ok) {
    Write-Host "`n=== DIAGNOSTIC INFO ===" -ForegroundColor Cyan
    Write-Host "--- Cybereason services ---"
    Get-Service *Cybereason* -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
    Write-Host "--- Cybereason processes ---"
    Get-Process minionhost, ActiveConsole -ErrorAction SilentlyContinue | Format-Table Name, Id -AutoSize
    Write-Host "--- C:\Program Files\Cybereason\ ---"
    Get-ChildItem "C:\Program Files\Cybereason" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object FullName
    Write-Host "--- Recent Application event log entries ---"
    Get-WinEvent -LogName Application -MaxEvents 20 -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-10) } |
        Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap -AutoSize
    Write-Host "--- Recent System event log entries ---"
    Get-WinEvent -LogName System -MaxEvents 20 -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-10) } |
        Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap -AutoSize
    Write-Host "--- MsiInstaller log (last 20) ---"
    Get-WinEvent -ProviderName MsiInstaller -MaxEvents 20 -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-10) } |
        Format-Table TimeCreated, Id, Message -Wrap -AutoSize
    Write-Host "=== END DIAGNOSTIC INFO ===" -ForegroundColor Cyan

    if ($lastResult -ne 0) {
        Write-Host "[ERROR] Install exit code was $lastResult AND services failed to start" -ForegroundColor Red
        exit 1
    }
    Write-Host "[ERROR] Sensor services did not start within ${TimeoutSeconds}s" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Sensor installed and running with Phoenix backend" -ForegroundColor Green
