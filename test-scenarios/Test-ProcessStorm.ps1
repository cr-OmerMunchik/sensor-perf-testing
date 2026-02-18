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

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "process_storm" `
    -Description "Rapid process spawn/terminate ($ProcessCount processes x $Bursts bursts)"

New-Item -ItemType Directory -Path "C:\PerfTest\results" -Force | Out-Null

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

$results | Format-Table -AutoSize

$avgSpawn = ($results | Measure-Object -Property SpawnSec -Average).Average
$avgTerminate = ($results | Measure-Object -Property TerminateSec -Average).Average

Add-ScenarioMetric -Key "process_count_per_burst" -Value $ProcessCount
Add-ScenarioMetric -Key "bursts" -Value $Bursts
Add-ScenarioMetric -Key "avg_spawn_seconds" -Value ([math]::Round($avgSpawn, 2))
Add-ScenarioMetric -Key "avg_terminate_seconds" -Value ([math]::Round($avgTerminate, 2))
Add-ScenarioMetric -Key "total_processes_spawned" -Value ($ProcessCount * $Bursts)
Add-ScenarioMetric -Key "expected_events" -Value "PROCESS_CREATED, PROCESS_ENDED, MODULE_LOADED"

Complete-Scenario
