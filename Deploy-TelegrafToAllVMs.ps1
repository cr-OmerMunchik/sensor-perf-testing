<#
.SYNOPSIS
    Deploys Telegraf to VM1-VM4 with num_cores and sensor_version tags.

.DESCRIPTION
    SCPs setup-telegraf/ to each test VM and runs Install-Telegraf.ps1 with
    the correct parameters. VM1 and VM4: no sensor. VM2 and VM3: sensor with
    auto-detected version.

.PARAMETER Token
    InfluxDB API token. Defaults to $env:INFLUXDB_TOKEN.

.EXAMPLE
    $env:INFLUXDB_TOKEN = "your-token"
    .\Deploy-TelegrafToAllVMs.ps1

    .\Deploy-TelegrafToAllVMs.ps1 -Token "your-token"
#>

param(
    [string]$Token = $env:INFLUXDB_TOKEN
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupTelegrafPath = Join-Path $scriptDir "setup-telegraf"

if (-not $Token) {
    Write-Error "Set INFLUXDB_TOKEN or pass -Token"
    exit 1
}

if (-not (Test-Path $setupTelegrafPath)) {
    Write-Error "setup-telegraf folder not found at $setupTelegrafPath"
    exit 1
}

$MonVmIp = "172.46.16.24"
$sshUser = "admin"

$vms = @(
    @{ Ip = "172.46.16.37";  SensorInstalled = "no";  Name = "VM1" },
    @{ Ip = "172.46.17.49";  SensorInstalled = "yes"; Name = "VM2" },
    @{ Ip = "172.46.16.176"; SensorInstalled = "yes"; Name = "VM3" },
    @{ Ip = "172.46.21.24";  SensorInstalled = "no";  Name = "VM4" }
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Deploy Telegraf to VM1-VM4" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  MON VM   : $MonVmIp" -ForegroundColor White
Write-Host "  Token    : $(if ($Token.Length -gt 8) { $Token.Substring(0,8) + '...' } else { '(invalid)' })" -ForegroundColor White
Write-Host ""

foreach ($vm in $vms) {
    $ip = $vm.Ip
    $sensor = $vm.SensorInstalled
    $name = $vm.Name

    Write-Host ">>> Deploying to $name ($ip) [sensor=$sensor] <<<" -ForegroundColor Cyan

    # Create remote dir (use cmd - default SSH shell on Windows is often cmd)
    ssh -o StrictHostKeyChecking=no "${sshUser}@${ip}" "cmd /c mkdir C:\PerfTest\setup-telegraf 2>nul"

    # SCP setup-telegraf files
    scp -o StrictHostKeyChecking=no "$setupTelegrafPath\Install-Telegraf.ps1" "$setupTelegrafPath\telegraf.conf" "${sshUser}@${ip}:C:\PerfTest\setup-telegraf\"

    # Build Install-Telegraf args (do NOT wrap token in quotes - cmd.exe passes them literally)
    $argList = "-MonVmIp $MonVmIp -InfluxToken $Token -SensorInstalled $sensor -NumCores 8"

    # Run Install-Telegraf (requires Admin - run from elevated PowerShell if needed)
    $cmd = "powershell -ExecutionPolicy Bypass -File C:\PerfTest\setup-telegraf\Install-Telegraf.ps1 $argList"
    ssh -o StrictHostKeyChecking=no "${sshUser}@${ip}" $cmd

    Write-Host "    Done: $name`n" -ForegroundColor Green
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " All VMs deployed. Verify: Get-Service telegraf" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
