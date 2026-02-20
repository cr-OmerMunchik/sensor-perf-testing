#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs a sustained soak test for extended periods (hours/days).

.DESCRIPTION
    Launches the combined_high_density scenario in a loop for a specified
    total duration. Designed for Phase 2 testing: detecting memory leaks,
    handle leaks, and sustained performance degradation.

    Can run in the foreground (interactive) or launch a detached background
    process that survives SSH disconnects.

    Each cycle runs combined_high_density for CycleMinutes, then pauses
    briefly before the next cycle. The scenario tag stays constant so
    Grafana shows clean, continuous graphs.

.PARAMETER DurationHours
    Total soak test duration in hours. Default: 8.

.PARAMETER CycleMinutes
    Duration of each combined_high_density cycle in minutes. Default: 60.
    After each cycle, a 60-second pause allows metrics to settle.

.PARAMETER Detached
    If set, launches the soak test as a background process and exits.
    The test continues even if you close the SSH session.

.EXAMPLE
    # Interactive 8-hour soak test
    .\Run-SoakTest.ps1

    # Quick 2-hour soak test
    .\Run-SoakTest.ps1 -DurationHours 2

    # Detached 48-hour (2-day) soak test (survives SSH disconnect)
    .\Run-SoakTest.ps1 -DurationHours 48 -Detached

    # Shorter cycles for more frequent progress logging
    .\Run-SoakTest.ps1 -DurationHours 8 -CycleMinutes 30
#>

param(
    [int]$DurationHours = 8,
    [int]$CycleMinutes = 60,
    [switch]$Detached
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$logDir = "C:\PerfTest\soak-logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

if ($Detached) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logFile = "$logDir\soak_${timestamp}.log"

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " Launching DETACHED Soak Test" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Duration    : $DurationHours hours" -ForegroundColor White
    Write-Host "  Cycle       : $CycleMinutes min each" -ForegroundColor White
    Write-Host "  Log file    : $logFile" -ForegroundColor White
    Write-Host "  PID file    : $logDir\soak.pid" -ForegroundColor White
    Write-Host "" -ForegroundColor White

    $proc = Start-Process powershell -ArgumentList @(
        "-ExecutionPolicy", "Bypass",
        "-File", "$scriptDir\Run-SoakTest.ps1",
        "-DurationHours", $DurationHours,
        "-CycleMinutes", $CycleMinutes
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $logFile -RedirectStandardError "$logDir\soak_${timestamp}_err.log"

    $proc.Id | Set-Content "$logDir\soak.pid"

    Write-Host "[OK] Soak test launched as PID $($proc.Id)" -ForegroundColor Green
    Write-Host "" -ForegroundColor White
    Write-Host "You can safely close this SSH session." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor White
    Write-Host "To monitor progress:" -ForegroundColor Yellow
    Write-Host "  Get-Content $logFile -Tail 20" -ForegroundColor Gray
    Write-Host "" -ForegroundColor White
    Write-Host "To stop the soak test:" -ForegroundColor Yellow
    Write-Host "  Stop-Process -Id $($proc.Id)" -ForegroundColor Gray
    Write-Host "  # Or:" -ForegroundColor Gray
    Write-Host "  Stop-Process -Id (Get-Content $logDir\soak.pid)" -ForegroundColor Gray
    exit 0
}

# ---------- Interactive (foreground) mode ----------

. "$scriptDir\ScenarioHelpers.ps1"

$totalSeconds = $DurationHours * 3600
$cycleSeconds = $CycleMinutes * 60
$totalCycles = [math]::Ceiling($totalSeconds / $cycleSeconds)
$suiteStart = Get-Date
$suiteEnd = $suiteStart.AddHours($DurationHours)

Start-Scenario -Name "soak_test" `
    -Description "Sustained soak test ($DurationHours hours, $CycleMinutes-min cycles)"

Write-Host "Soak test plan:" -ForegroundColor Yellow
Write-Host "  Total duration : $DurationHours hours" -ForegroundColor White
Write-Host "  Cycle length   : $CycleMinutes minutes" -ForegroundColor White
Write-Host "  Total cycles   : ~$totalCycles" -ForegroundColor White
Write-Host "  End time       : $($suiteEnd.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
Write-Host ""

$testDir = "C:\PerfTest\soak_combined"
$regPath = "HKCU:\Software\PerfTest_Soak"
$cycleNum = 0

while ((Get-Date) -lt $suiteEnd) {
    $cycleNum++
    $cycleStart = Get-Date
    $remaining = $suiteEnd - $cycleStart
    $remainingHours = [math]::Round($remaining.TotalHours, 1)

    Write-Host "`n--- Cycle $cycleNum | $remainingHours hours remaining ---" -ForegroundColor Cyan

    # Calculate how long this cycle should run (don't exceed total end time)
    $thisCycleSeconds = [math]::Min($cycleSeconds, ($suiteEnd - (Get-Date)).TotalSeconds)
    if ($thisCycleSeconds -le 0) { break }

    # Prepare directories
    New-Item -ItemType Directory -Path "$testDir\files" -Force | Out-Null
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

    # Launch background generators
    $fileJob = Start-Job -ScriptBlock {
        param($dir, $count, $durationSec)
        $endTime = (Get-Date).AddSeconds($durationSec)
        $totalOps = 0
        while ((Get-Date) -lt $endTime) {
            for ($i = 1; $i -le $count; $i++) {
                $file = "$dir\test$i.txt"
                $renamed = "$dir\renamed$i.txt"
                try {
                    [System.IO.File]::WriteAllText($file, "soak test $i")
                    [System.IO.File]::Move($file, $renamed)
                    [System.IO.File]::Delete($renamed)
                    $totalOps += 3
                } catch {}
            }
        }
        $totalOps
    } -ArgumentList "$testDir\files", 500, $thisCycleSeconds

    $regJob = Start-Job -ScriptBlock {
        param($path, $count, $durationSec)
        $endTime = (Get-Date).AddSeconds($durationSec)
        $totalOps = 0
        while ((Get-Date) -lt $endTime) {
            for ($i = 1; $i -le $count; $i++) {
                try {
                    New-ItemProperty -Path $path -Name "Val$i" -Value "soak$i" -PropertyType String -Force | Out-Null
                    Remove-ItemProperty -Path $path -Name "Val$i" -ErrorAction SilentlyContinue
                    $totalOps += 2
                } catch {}
            }
        }
        $totalOps
    } -ArgumentList $regPath, 300, $thisCycleSeconds

    $netJob = Start-Job -ScriptBlock {
        param($durationSec)
        $endTime = (Get-Date).AddSeconds($durationSec)
        $totalReqs = 0
        while ((Get-Date) -lt $endTime) {
            try {
                Invoke-WebRequest -Uri "https://example.com" -UseBasicParsing -TimeoutSec 5 | Out-Null
            } catch {}
            $totalReqs++
            Start-Sleep -Milliseconds 500
        }
        $totalReqs
    } -ArgumentList $thisCycleSeconds

    # Wait for cycle to complete with progress updates
    $cycleEndTime = (Get-Date).AddSeconds($thisCycleSeconds)
    while ((Get-Date) -lt $cycleEndTime) {
        $elapsed = ((Get-Date) - $suiteStart).TotalHours
        $totalPct = [math]::Min(100, [math]::Round(($elapsed / $DurationHours) * 100))
        $cycleElapsed = ((Get-Date) - $cycleStart).TotalMinutes
        $cycleRemaining = [math]::Round(($thisCycleSeconds / 60) - $cycleElapsed, 1)

        Write-Progress -Activity "Soak Test ($DurationHours hours)" `
            -Status "Cycle $cycleNum | $cycleRemaining min left in cycle | $remainingHours hrs total remaining" `
            -PercentComplete $totalPct

        Start-Sleep -Seconds 30
    }

    # Collect results
    $fileOps = Receive-Job $fileJob -Wait -ErrorAction SilentlyContinue
    $regOps = Receive-Job $regJob -Wait -ErrorAction SilentlyContinue
    $netReqs = Receive-Job $netJob -Wait -ErrorAction SilentlyContinue
    Remove-Job $fileJob, $regJob, $netJob -Force -ErrorAction SilentlyContinue

    $cycleDuration = [math]::Round(((Get-Date) - $cycleStart).TotalMinutes, 1)
    Write-Host "  Cycle $cycleNum complete: ${cycleDuration}min | file_ops=$fileOps reg_ops=$regOps net_reqs=$netReqs" -ForegroundColor Green

    # Brief pause between cycles
    if ((Get-Date) -lt $suiteEnd) {
        Write-Host "  Pausing 60s before next cycle..." -ForegroundColor Gray
        Start-Sleep -Seconds 60
    }
}

Write-Progress -Activity "Soak Test" -Completed

# Cleanup
Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue

# Record final metrics
$totalDuration = ((Get-Date) - $suiteStart).TotalHours
Add-ScenarioMetric -Key "total_hours" -Value ([math]::Round($totalDuration, 2))
Add-ScenarioMetric -Key "total_cycles" -Value $cycleNum
Add-ScenarioMetric -Key "cycle_minutes" -Value $CycleMinutes
Add-ScenarioMetric -Key "generators" -Value "file_stress, registry_storm, network_burst"

Complete-Scenario

Write-Host ""
Write-Host "What to check in Grafana:" -ForegroundColor Yellow
Write-Host "  1. Set time range to cover the full soak test" -ForegroundColor White
Write-Host "  2. Set Scenario = 'soak_test'" -ForegroundColor White
Write-Host "  3. Look for UPWARD TRENDS in:" -ForegroundColor White
Write-Host "     - Private Bytes (memory leak)" -ForegroundColor White
Write-Host "     - Handle Count (handle leak)" -ForegroundColor White
Write-Host "     - Kernel Pool Memory (driver leak)" -ForegroundColor White
Write-Host "  4. Flat lines = GOOD. Rising lines = LEAK." -ForegroundColor White
