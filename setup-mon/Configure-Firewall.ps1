#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Opens firewall ports for InfluxDB (8086) and Grafana (3000) on the MON VM.

.NOTES
    Run this script on the MON VM.
#>

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Firewall Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$rules = @(
    @{ Name = "InfluxDB (TCP 8086)"; Port = 8086; Description = "Allow Telegraf agents to push metrics to InfluxDB" },
    @{ Name = "Grafana (TCP 3000)"; Port = 3000; Description = "Allow browser access to Grafana dashboards" }
)

foreach ($rule in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "[SKIP] Rule '$($rule.Name)' already exists." -ForegroundColor Yellow
    }
    else {
        New-NetFirewallRule `
            -DisplayName $rule.Name `
            -Description $rule.Description `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $rule.Port `
            -Action Allow `
            -Profile Any | Out-Null
        Write-Host "[OK] Created rule: $($rule.Name)" -ForegroundColor Green
    }
}

Write-Host "`n[OK] Firewall configured. Ports 8086 and 3000 are open." -ForegroundColor Green
