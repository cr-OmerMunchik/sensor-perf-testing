<#
.SYNOPSIS
    Switches the Telegraf scenario tag and restarts the service.

.DESCRIPTION
    Updates the scenario tag in telegraf.conf and restarts the Telegraf service.
    Use this before starting each test to properly tag the collected metrics.

.PARAMETER Scenario
    The scenario name to set. Available scenarios:
      idle_baseline, file_stress_loop, registry_storm, network_burst,
      process_storm, rpc_generation, service_cycle, user_account_modify,
      browser_streaming, zip_extraction, file_storm, driver_load,
      combined_high_density, soak_test

.EXAMPLE
    .\Switch-Scenario.ps1 -Scenario "zip_extraction"
    .\Switch-Scenario.ps1 -Scenario "idle_baseline"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Scenario
)

$confPath = "C:\InfluxData\telegraf\telegraf.conf"

if (-not (Test-Path $confPath)) {
    Write-Host "[WARN] Telegraf config not found at $confPath - skipping scenario tag switch." -ForegroundColor Yellow
    Write-Host "       Metrics will not be tagged with scenario='$Scenario'." -ForegroundColor Yellow
    return
}

$content = Get-Content $confPath -Raw
$newContent = $content -replace '  scenario = ".*"', "  scenario = `"$Scenario`""

if ($content -eq $newContent) {
    Write-Host "[WARN] No change detected. Pattern 'scenario = `"...`"' may not exist in config." -ForegroundColor Yellow
}
else {
    Set-Content -Path $confPath -Value $newContent -Encoding UTF8
    Write-Host "[OK] Scenario set to: $Scenario" -ForegroundColor Green
}

$svc = Get-Service telegraf -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "[WARN] Telegraf service not found - skipping restart." -ForegroundColor Yellow
    return
}

Write-Host "Restarting Telegraf service..." -ForegroundColor Cyan
Restart-Service telegraf
Start-Sleep -Seconds 2

$svc = Get-Service telegraf
if ($svc.Status -eq "Running") {
    Write-Host "[OK] Telegraf restarted. Metrics are now tagged with scenario='$Scenario'" -ForegroundColor Green
}
else {
    Write-Host "[ERROR] Telegraf is not running after restart." -ForegroundColor Red
}
