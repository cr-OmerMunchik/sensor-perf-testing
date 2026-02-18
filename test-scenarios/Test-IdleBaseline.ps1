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

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "idle_baseline" `
    -Description "Idle baseline ($DurationMinutes minutes)"

$startTime = Get-Date
$endTime = $startTime.AddMinutes($DurationMinutes)

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

Add-ScenarioMetric -Key "duration_minutes" -Value $DurationMinutes
Add-ScenarioMetric -Key "expected_events" -Value "Minimal (idle system)"

Complete-Scenario
