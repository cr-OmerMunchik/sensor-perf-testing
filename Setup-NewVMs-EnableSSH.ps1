#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Run this ON EACH NEW VM via RDP to enable SSH.
    After this, the workstation can manage the VM remotely.

.DESCRIPTION
    1. Installs OpenSSH Server
    2. Starts and auto-starts the sshd service
    3. Opens firewall port 22
    4. Sets default shell to PowerShell (so remote commands use PowerShell, not cmd)
#>
$ErrorActionPreference = "Stop"

Write-Host "=== Enabling SSH on $(hostname) ===" -ForegroundColor Cyan

Write-Host "[1/4] Installing OpenSSH Server..." -ForegroundColor White
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue | Out-Null
Write-Host "      Done." -ForegroundColor Green

Write-Host "[2/4] Starting sshd service..." -ForegroundColor White
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
Write-Host "      sshd is running and set to auto-start." -ForegroundColor Green

Write-Host "[3/4] Opening firewall port 22..." -ForegroundColor White
$existing = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if (-not $existing) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (TCP 22)" `
        -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
}
Write-Host "      Firewall rule OK." -ForegroundColor Green

Write-Host "[4/4] Setting default SSH shell to PowerShell..." -ForegroundColor White
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -PropertyType String -Force | Out-Null
Write-Host "      Default shell set to PowerShell." -ForegroundColor Green

Write-Host "`n=== SSH is ready on $(hostname) ===" -ForegroundColor Cyan
Write-Host "From your workstation, run: ssh admin@<this-VM-IP> hostname" -ForegroundColor Yellow
