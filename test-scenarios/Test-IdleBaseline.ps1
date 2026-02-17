<#
.SYNOPSIS
    Runs the Idle Baseline test scenario.

.DESCRIPTION
    Sets the scenario tag to "idle_baseline", restarts Telegraf, and waits
    for the specified duration while the system sits idle. This establishes
    the baseline resource consumption.

    Run this on BOTH VMs simultaneously.

.PARAMETER DurationMinutes
    How long to run the idle test. Default: 60 minutes (1 hour).
    For full validation per the testing plan, use 480-1440 (8-24 hours).

.EXAMPLE
    # Quick validation (1 hour)
    .\Test-IdleBaseline.ps1

    # Full baseline (8 hours)
    .\Test-IdleBaseline.ps1 -DurationMinutes 480
#>

param(
    [int]$DurationMinutes = 60
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Idle Baseline Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Duration : $DurationMinutes minutes" -ForegroundColor White
Write-Host "  Host     : $env:COMPUTERNAME" -ForegroundColor White

# Switch scenario tag
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$scriptDir\Switch-Scenario.ps1" -Scenario "idle_baseline"

$startTime = Get-Date
$endTime = $startTime.AddMinutes($DurationMinutes)

Write-Host "`nTest started at   : $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
Write-Host "Test will end at  : $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
Write-Host ""
Write-Host "System is now idle. Telegraf is collecting metrics every 10 seconds." -ForegroundColor Yellow
Write-Host "Do NOT interact with the VM during this test." -ForegroundColor Yellow
Write-Host ""

$progressInterval = [math]::Max(1, [math]::Floor($DurationMinutes / 20))

while ((Get-Date) -lt $endTime) {
    $elapsed = (Get-Date) - $startTime
    $remaining = $endTime - (Get-Date)
    $pct = [math]::Min(100, [math]::Round(($elapsed.TotalMinutes / $DurationMinutes) * 100))

    Write-Progress -Activity "Idle Baseline Test" `
        -Status "$pct% complete - $([math]::Round($remaining.TotalMinutes)) min remaining" `
        -PercentComplete $pct

    Start-Sleep -Seconds ($progressInterval * 60)
}

Write-Progress -Activity "Idle Baseline Test" -Completed

$actualEnd = Get-Date
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Idle Baseline Test COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Started  : $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
Write-Host "  Ended    : $($actualEnd.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
Write-Host "  Duration : $([math]::Round(($actualEnd - $startTime).TotalMinutes)) minutes" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open Grafana and set time range to cover this test" -ForegroundColor White
Write-Host "  2. Select this host in the Host dropdown" -ForegroundColor White
Write-Host "  3. Select 'idle_baseline' in the Scenario dropdown" -ForegroundColor White
Write-Host "  4. Verify KPIs:" -ForegroundColor White
Write-Host "     - CPU should be near 0% (< 2%)" -ForegroundColor White
Write-Host "     - Sensor memory (Working Set) should be < 350 MB" -ForegroundColor White
Write-Host "     - Handle count should be stable (no upward trend)" -ForegroundColor White
