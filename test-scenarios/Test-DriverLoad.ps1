#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Scenario 9: Driver Load (via Windows Defender service restart)

.DESCRIPTION
    Restarts Windows Defender service which loads the driver stack.
    Generates: DRIVER_LOADED, SERVICE_STARTED, SERVICE_STOPPED

    Low frequency but useful for driver load event validation.

.PARAMETER Cycles
    Number of stop/start cycles. Default: 3.

.EXAMPLE
    .\Test-DriverLoad.ps1
    .\Test-DriverLoad.ps1 -Cycles 5
#>

param(
    [int]$Cycles = 3
)

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "driver_load" `
    -Description "Driver load via Defender restart ($Cycles cycles)"

$successCount = 0

for ($i = 1; $i -le $Cycles; $i++) {
    Write-Host "  Cycle $i of $Cycles..." -ForegroundColor Gray -NoNewline

    try {
        # Stop Defender service (may require tampering protection to be off)
        & sc.exe stop WinDefend 2>&1 | Out-Null
        Start-Sleep -Seconds 3

        # Start Defender service (loads driver stack)
        & sc.exe start WinDefend 2>&1 | Out-Null
        Start-Sleep -Seconds 5

        $successCount++
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        Write-Host " ERROR (Defender may be protected)" -ForegroundColor Yellow
    }
}

if ($successCount -eq 0) {
    Write-Host "`n[NOTE] If all cycles failed, Windows Defender tamper protection" -ForegroundColor Yellow
    Write-Host "       may be blocking service control. This is expected on" -ForegroundColor Yellow
    Write-Host "       modern Windows 11. Consider disabling tamper protection" -ForegroundColor Yellow
    Write-Host "       in Windows Security settings, or use an alternative" -ForegroundColor Yellow
    Write-Host "       driver-loading method." -ForegroundColor Yellow
}

Add-ScenarioMetric -Key "cycles" -Value $Cycles
Add-ScenarioMetric -Key "success_count" -Value $successCount
Add-ScenarioMetric -Key "expected_events" -Value "DRIVER_LOADED, SERVICE_STARTED, SERVICE_STOPPED"
Add-ScenarioMetric -Key "estimated_driver_events" -Value ($Cycles * 3)

Complete-Scenario
