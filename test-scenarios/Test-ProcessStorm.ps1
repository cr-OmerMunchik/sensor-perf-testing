<#
.SYNOPSIS
    Runs the Process Storm test scenario.

.DESCRIPTION
    Rapidly spawns and terminates processes to stress the sensor's process
    monitoring capabilities. Measures CPU spike duration and recovery.

    Run this on BOTH VMs to compare with/without sensor.

.PARAMETER ProcessCount
    Number of processes to spawn per burst. Default: 200.

.PARAMETER Bursts
    Number of spawn/terminate bursts. Default: 5.

.EXAMPLE
    .\Test-ProcessStorm.ps1
    .\Test-ProcessStorm.ps1 -ProcessCount 500 -Bursts 10
#>

param(
    [int]$ProcessCount = 200,
    [int]$Bursts = 5
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Process Storm Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Host            : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  Processes/burst : $ProcessCount" -ForegroundColor White
Write-Host "  Bursts          : $Bursts" -ForegroundColor White

# Switch scenario tag
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$scriptDir\Switch-Scenario.ps1" -Scenario "process_storm"

Start-Sleep -Seconds 5

$results = @()
for ($burst = 1; $burst -le $Bursts; $burst++) {
    Write-Host "`n--- Burst $burst of $Bursts ---" -ForegroundColor Cyan

    # SPAWN phase
    Write-Host "  Spawning $ProcessCount processes..." -ForegroundColor White -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $procs = @()
    for ($i = 1; $i -le $ProcessCount; $i++) {
        $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c echo process_$i && timeout /t 5 /nobreak >nul" `
            -WindowStyle Hidden -PassThru
        $procs += $p
    }
    $sw.Stop()
    $spawnTime = $sw.Elapsed.TotalSeconds
    Write-Host " $([math]::Round($spawnTime, 2))s" -ForegroundColor Green

    # Let processes run briefly
    Write-Host "  Waiting for processes to complete..." -ForegroundColor Gray
    Start-Sleep -Seconds 8

    # TERMINATE remaining
    Write-Host "  Terminating remaining processes..." -ForegroundColor White -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $procs | ForEach-Object {
        if (-not $_.HasExited) {
            $_ | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    $sw.Stop()
    $terminateTime = $sw.Elapsed.TotalSeconds
    Write-Host " $([math]::Round($terminateTime, 2))s" -ForegroundColor Green

    $results += [PSCustomObject]@{
        Burst        = $burst
        SpawnSec     = [math]::Round($spawnTime, 2)
        TerminateSec = [math]::Round($terminateTime, 2)
    }

    # Recovery pause
    if ($burst -lt $Bursts) {
        Write-Host "  Pausing 15 seconds for recovery..." -ForegroundColor Gray
        Start-Sleep -Seconds 15
    }
}

# ---------- Results ----------
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Process Storm Test COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
$results | Format-Table -AutoSize

$resultsFile = "C:\PerfTest\results_process_storm_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$results | Format-Table -AutoSize | Out-File $resultsFile
Write-Host "`nResults saved to: $resultsFile" -ForegroundColor Yellow
Write-Host ""
Write-Host "Check Grafana for CPU spike duration and recovery time." -ForegroundColor Yellow
