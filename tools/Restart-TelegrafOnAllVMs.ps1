# Restart Telegraf on all test VMs (VM1-VM4)
# Use when Grafana shows "No data" and influx-check-recent shows stale data
param(
    [string]$SshUser = "admin"
)
$ErrorActionPreference = "Continue"
$vms = @(
    @{ Ip = "172.46.16.37";  Name = "VM1 (TEST-PERF-1)" },
    @{ Ip = "172.46.17.49";  Name = "VM2 (TEST-PERF-2)" },
    @{ Ip = "172.46.16.176"; Name = "VM3 (TEST-PERF-3)" },
    @{ Ip = "172.46.21.24";  Name = "VM4 (TEST-PERF-4)" }
)
Write-Host "`n Restarting Telegraf on all test VMs" -ForegroundColor Cyan
foreach ($vm in $vms) {
    Write-Host "`n  $($vm.Name) ($($vm.Ip))..." -ForegroundColor White
    try {
        $out = ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SshUser}@$($vm.Ip)" "powershell -NoProfile -Command \"Restart-Service telegraf -ErrorAction Stop; Write-Host OK\""
        if ($out -match "OK") { Write-Host "    Restarted." -ForegroundColor Green } else { Write-Host "    $out" -ForegroundColor Gray }
    } catch {
        Write-Host "    Failed: $_" -ForegroundColor Red
    }
}
Write-Host "`nDone. Wait 1-2 minutes, then run .\tools\run-influx-check-on-mon.ps1 to verify data." -ForegroundColor Yellow
