<#
.SYNOPSIS
    Deploys your SSH public key to all perf-testing VMs for password-less access.

.DESCRIPTION
    Copies your ed25519 public key to each VM's administrators_authorized_keys file
    and sets the correct ACL. You will be prompted for the password once per VM.
    After this, SSH and SCP will work without passwords.

.NOTES
    Run this from your workstation in PowerShell.
#>

$pubkeyPath = "$env:USERPROFILE\.ssh\id_ed25519.pub"

if (-not (Test-Path $pubkeyPath)) {
    Write-Host "[ERROR] No SSH key found at $pubkeyPath" -ForegroundColor Red
    Write-Host "Generate one first: ssh-keygen -t ed25519" -ForegroundColor Yellow
    exit 1
}

$pubkey = Get-Content $pubkeyPath
Write-Host "Using public key: $pubkey`n" -ForegroundColor Gray

$vms = @(
    "172.46.16.24",   # test_perf_mon
    "172.46.16.37",   # test_perf_1
    "172.46.17.49",   # test_perf_2
    "172.46.16.176",  # test_perf_3
    "172.46.21.24"    # test_perf_4
)

foreach ($vm in $vms) {
    Write-Host ">>> Setting up SSH key on $vm <<<" -ForegroundColor Cyan

    # Step 1: Copy public key to temp location on the VM
    scp -o StrictHostKeyChecking=no $pubkeyPath "admin@${vm}:C:\pubkey.tmp"

    # Step 2: Move to the right place and set ACL using cmd.exe-compatible commands
    ssh -o StrictHostKeyChecking=no admin@$vm "mkdir C:\ProgramData\ssh 2>nul & copy /Y C:\pubkey.tmp C:\ProgramData\ssh\administrators_authorized_keys & icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant SYSTEM:(F) /grant Administrators:(F) & del C:\pubkey.tmp"

    Write-Host "    Done: $vm`n" -ForegroundColor Green
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Testing password-less SSH" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

foreach ($vm in $vms) {
    $result = ssh -o BatchMode=yes -o ConnectTimeout=5 admin@$vm "hostname" 2>$null
    if ($result) {
        Write-Host "    $vm -> $result [OK]" -ForegroundColor Green
    }
    else {
        Write-Host "    $vm -> FAILED (still asking for password?)" -ForegroundColor Red
    }
}
