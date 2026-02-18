#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Scenario 5: Service Start/Stop Cycle (Low Volume, Precise)

.DESCRIPTION
    Creates a test Windows service, starts it, stops it, and deletes it.
    Generates: SERVICE_STARTED, SERVICE_STOPPED, PROCESS_CREATED, DRIVER_LOADED (sometimes)

    Low noise, good for validating service monitoring pipeline.

.PARAMETER Cycles
    Number of create/start/stop/delete cycles. Default: 10.

.EXAMPLE
    .\Test-ServiceCycle.ps1
    .\Test-ServiceCycle.ps1 -Cycles 25
#>

param(
    [int]$Cycles = 10
)

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "service_cycle" `
    -Description "Service create/start/stop/delete ($Cycles cycles)"

$successCount = 0
$errorCount = 0

for ($i = 1; $i -le $Cycles; $i++) {
    $svcName = "PerfTestSvc_$i"
    Write-Host "  Cycle $i of $Cycles ($svcName)..." -ForegroundColor Gray -NoNewline

    try {
        # Cleanup from previous failed run
        & sc.exe stop $svcName 2>&1 | Out-Null
        & sc.exe delete $svcName 2>&1 | Out-Null
        Start-Sleep -Milliseconds 200

        # Create
        & sc.exe create $svcName binPath= "C:\Windows\System32\cmd.exe /c timeout /t 30" start= demand type= own 2>&1 | Out-Null

        # Start (will fail quickly since cmd.exe isn't a real service, but it generates the events)
        & sc.exe start $svcName 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500

        # Stop
        & sc.exe stop $svcName 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500

        # Delete
        & sc.exe delete $svcName 2>&1 | Out-Null

        $successCount++
        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        $errorCount++
        Write-Host " ERROR" -ForegroundColor Red
        # Cleanup
        & sc.exe delete $svcName 2>&1 | Out-Null
    }

    Start-Sleep -Seconds 1
}

Add-ScenarioMetric -Key "cycles" -Value $Cycles
Add-ScenarioMetric -Key "success_count" -Value $successCount
Add-ScenarioMetric -Key "error_count" -Value $errorCount
Add-ScenarioMetric -Key "expected_events" -Value "SERVICE_STARTED, SERVICE_STOPPED, PROCESS_CREATED, DRIVER_LOADED (sometimes)"
Add-ScenarioMetric -Key "estimated_service_events" -Value ($Cycles * 2)

Complete-Scenario
