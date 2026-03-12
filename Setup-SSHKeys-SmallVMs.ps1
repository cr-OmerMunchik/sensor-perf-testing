$pubkey = "$env:USERPROFILE\.ssh\id_ed25519.pub"
foreach ($ip in @("172.46.17.140","172.46.16.179","172.46.17.21","172.46.17.40")) {
    Write-Host ">>> $ip <<<" -ForegroundColor Cyan
    scp -o StrictHostKeyChecking=no $pubkey "admin@${ip}:C:\pubkey.tmp"
    ssh -o StrictHostKeyChecking=no "admin@${ip}" "mkdir C:\ProgramData\ssh 2>`$null; Copy-Item C:\pubkey.tmp C:\ProgramData\ssh\administrators_authorized_keys -Force; icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant SYSTEM:'(F)' /grant Administrators:'(F)'; Remove-Item C:\pubkey.tmp -Force; Write-Host 'Done'"
}
