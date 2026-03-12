$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir
$confSource = Join-Path $repoRoot "setup-telegraf\telegraf.conf"
$sshUser = "admin"
$MonVmIp = "172.46.16.24"
$Token = "TXAx5RsDsBxHqCgaGbeKEZWEHprToZUIEuQ5MfCehnhgv8g-0q836nnw9Y3fF5CN8RxIqJtLNqFS2ZCxkv3dQA=="

$vms = @(
    @{ Ip = "172.46.17.140"; SensorInstalled = "no";  SensorVersion = "";      BackendType = "";        VmSize = "small"; NumCores = 2 },
    @{ Ip = "172.46.16.179"; SensorInstalled = "yes"; SensorVersion = "26.1";  BackendType = "phoenix"; VmSize = "small"; NumCores = 2 },
    @{ Ip = "172.46.17.21";  SensorInstalled = "yes"; SensorVersion = "26.1";  BackendType = "legacy";  VmSize = "small"; NumCores = 2 },
    @{ Ip = "172.46.17.40";  SensorInstalled = "yes"; SensorVersion = "24.1";  BackendType = "legacy";  VmSize = "small"; NumCores = 2 }
)

$confTemplate = Get-Content $confSource -Raw

foreach ($vm in $vms) {
    $ip = $vm.Ip
    Write-Host "`n>>> Updating $ip <<<" -ForegroundColor Cyan

    $conf = $confTemplate
    $conf = $conf -replace 'MON_VM_IP', $MonVmIp
    $conf = $conf -replace 'INFLUXDB_TOKEN', $Token
    $conf = $conf -replace '  sensor_installed = "no"', "  sensor_installed = `"$($vm.SensorInstalled)`""
    $conf = $conf -replace '  sensor_version = ""', "  sensor_version = `"$($vm.SensorVersion)`""
    $conf = $conf -replace '  machine_profile = "large_8vcpu_16gb"', "  machine_profile = `"small_2vcpu_4gb`""
    $conf = $conf -replace '  num_cores = "8"', "  num_cores = `"$($vm.NumCores)`""
    $conf = $conf -replace '  backend_type = ""', "  backend_type = `"$($vm.BackendType)`""
    $conf = $conf -replace '  vm_size = "large"', "  vm_size = `"$($vm.VmSize)`""

    $tempFile = Join-Path $env:TEMP "telegraf_$($ip -replace '\.','_').conf"
    Set-Content -Path $tempFile -Value $conf -Encoding UTF8 -NoNewline

    scp -o StrictHostKeyChecking=no $tempFile "${sshUser}@${ip}:C:/InfluxData/telegraf/telegraf.conf"
    ssh -o StrictHostKeyChecking=no "${sshUser}@${ip}" "Restart-Service telegraf -Force; Write-Host OK"

    Remove-Item $tempFile -Force
    Write-Host "    Done: $ip" -ForegroundColor Green
}

Write-Host "`nAll small VMs updated." -ForegroundColor Cyan
