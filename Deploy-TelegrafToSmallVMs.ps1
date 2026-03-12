<#
.SYNOPSIS
    Deploys Telegraf to the 4 small test VMs (TEST-PERF-S1 to S4).
.PARAMETER Token
    InfluxDB API token. Defaults to $env:INFLUXDB_TOKEN.
#>
param(
    [string]$Token = $env:INFLUXDB_TOKEN
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$setupTelegrafPath = Join-Path $scriptDir "setup-telegraf"

if (-not $Token) { Write-Error "Set INFLUXDB_TOKEN or pass -Token"; exit 1 }
if (-not (Test-Path $setupTelegrafPath)) { Write-Error "setup-telegraf folder not found"; exit 1 }

$MonVmIp = "172.46.16.24"
$sshUser = "admin"

$vms = @(
    @{ Ip = "172.46.17.140"; SensorInstalled = "no";  Name = "S1"; BackendType = "";        NumCores = 2 },
    @{ Ip = "172.46.16.179"; SensorInstalled = "yes"; Name = "S2"; BackendType = "phoenix";  NumCores = 2 },
    @{ Ip = "172.46.17.21";  SensorInstalled = "yes"; Name = "S3"; BackendType = "legacy";   NumCores = 2 },
    @{ Ip = "172.46.17.40";  SensorInstalled = "yes"; Name = "S4"; BackendType = "legacy";   NumCores = 2 }
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Deploy Telegraf to Small VMs (S1-S4)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

foreach ($vm in $vms) {
    $ip = $vm.Ip
    $sensor = $vm.SensorInstalled
    $name = $vm.Name
    $backend = $vm.BackendType
    $cores = $vm.NumCores

    Write-Host "`n>>> Deploying to $name ($ip) [sensor=$sensor, backend=$backend] <<<" -ForegroundColor Cyan

    ssh -o StrictHostKeyChecking=no "${sshUser}@${ip}" "New-Item -ItemType Directory -Path C:\PerfTest\setup-telegraf -Force | Out-Null"
    scp -o StrictHostKeyChecking=no "$setupTelegrafPath\Install-Telegraf.ps1" "$setupTelegrafPath\telegraf.conf" "${sshUser}@${ip}:C:/PerfTest/setup-telegraf/"

    $btArg = if ($backend) { $backend } else { '""' }
    $argList = "-MonVmIp $MonVmIp -InfluxToken $Token -SensorInstalled $sensor -NumCores $cores -MachineProfile small_2vcpu_4gb -BackendType $btArg -VmSize small"
    ssh -o StrictHostKeyChecking=no "${sshUser}@${ip}" "powershell -ExecutionPolicy Bypass -File C:\PerfTest\setup-telegraf\Install-Telegraf.ps1 $argList"

    Write-Host "    Done: $name" -ForegroundColor Green
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " All small VMs deployed." -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
