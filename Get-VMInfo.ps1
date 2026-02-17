<#
.SYNOPSIS
    Collects system information from a VM for performance testing setup.
    Run this on the existing VM and share the output.
#>

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " VM System Information" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`n--- OS Info ---" -ForegroundColor Yellow
Get-CimInstance Win32_OperatingSystem | Format-List Caption, Version, BuildNumber, OSArchitecture

Write-Host "--- Hardware ---" -ForegroundColor Yellow
$cpu = Get-CimInstance Win32_Processor
$mem = Get-CimInstance Win32_ComputerSystem
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
Write-Host "  CPU         : $($cpu.Name)"
Write-Host "  Cores       : $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) logical"
Write-Host "  RAM         : $([math]::Round($mem.TotalPhysicalMemory / 1GB, 1)) GB"
Write-Host "  Disk C:     : $([math]::Round($disk.Size / 1GB, 1)) GB total, $([math]::Round($disk.FreeSpace / 1GB, 1)) GB free"

Write-Host "`n--- Network ---" -ForegroundColor Yellow
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" } | Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize

Write-Host "--- Hostname ---" -ForegroundColor Yellow
Write-Host "  Hostname    : $env:COMPUTERNAME"

Write-Host "`n--- PowerShell Version ---" -ForegroundColor Yellow
Write-Host "  PS Version  : $($PSVersionTable.PSVersion)"

Write-Host "`n--- Windows Defender ---" -ForegroundColor Yellow
$defender = Get-Service WinDefend -ErrorAction SilentlyContinue
if ($defender) {
    Write-Host "  Status      : $($defender.Status)"
} else {
    Write-Host "  Status      : Not installed"
}
