# Fix Telegraf token on all VMs - removes erroneous single quotes around token
# Root cause: Deploy-TelegrafToAllVMs.ps1 passed -InfluxToken 'TOKEN' which cmd.exe
# passed literally (including quotes) to Install-Telegraf, so config had token = "'TOKEN'"
param([string]$SshUser = "admin")
$vms = @("172.46.16.37", "172.46.17.49", "172.46.16.176", "172.46.21.24")
$confPath = "C:\InfluxData\telegraf\telegraf.conf"
$fixScript = @'
$p = "C:\InfluxData\telegraf\telegraf.conf"
$c = Get-Content $p -Raw
$c = $c -replace 'token = "''([^'']+)''"', 'token = "$1"'
Set-Content $p -Value $c -NoNewline
Restart-Service telegraf -Force
Write-Host "OK"
'@
$fixScript | Out-File -Encoding ascii $env:TEMP\fix-telegraf-token.ps1
Write-Host "`n Fixing Telegraf token on all VMs" -ForegroundColor Cyan
foreach ($ip in $vms) {
  Write-Host "  $ip..." -NoNewline
  scp -o StrictHostKeyChecking=no -o ConnectTimeout=5 $env:TEMP\fix-telegraf-token.ps1 "${SshUser}@${ip}:C:\PerfTest\fix-token.ps1" 2>$null
  $out = ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SshUser}@${ip}" "powershell -NoProfile -ExecutionPolicy Bypass -File C:\PerfTest\fix-token.ps1" 2>&1
  if ($out -match "Fixed|Restarted") { Write-Host " OK" -ForegroundColor Green } else { Write-Host " $out" -ForegroundColor Yellow }
}
Write-Host "`nDone. Wait 1-2 min then run .\tools\run-influx-check-on-mon.ps1" -ForegroundColor Yellow
