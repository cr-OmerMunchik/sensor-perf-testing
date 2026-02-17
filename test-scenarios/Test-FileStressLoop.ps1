<#
.SYNOPSIS
    Scenario 2: File Stress Loop (Controlled High File Rate)

.DESCRIPTION
    Creates, renames, and deletes files in a tight loop.
    Generates: FILE_CREATED, FILE_RENAMED, FILE_DELETED,
    PROCESS_CREATED, MODULE_LOADED

    Highly controllable and deterministic.

.PARAMETER LoopCount
    Number of create-rename-delete cycles. Default: 1000.

.PARAMETER Iterations
    Number of times to repeat the full loop. Default: 3.

.EXAMPLE
    .\Test-FileStressLoop.ps1
    .\Test-FileStressLoop.ps1 -LoopCount 5000 -Iterations 5
#>

param(
    [int]$LoopCount = 1000,
    [int]$Iterations = 3
)

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "file_stress_loop" `
    -Description "File create/rename/delete loop (${LoopCount} files x ${Iterations} iterations)"

$testDir = "C:\PerfTest\file_stress"
New-Item -ItemType Directory -Path $testDir -Force | Out-Null

$totalEvents = 0
$timings = @()

for ($iter = 1; $iter -le $Iterations; $iter++) {
    Write-Host "Iteration $iter of $Iterations ($LoopCount files)..." -ForegroundColor White

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $LoopCount; $i++) {
        $file = "$testDir\test$i.txt"
        $renamed = "$testDir\renamed$i.txt"
        [System.IO.File]::WriteAllText($file, "test content $i")
        [System.IO.File]::Move($file, $renamed)
        [System.IO.File]::Delete($renamed)
    }
    $sw.Stop()

    $elapsed = $sw.Elapsed.TotalSeconds
    $rate = [math]::Round($LoopCount / $elapsed)
    $timings += $elapsed
    $totalEvents += $LoopCount * 3

    Write-Host "  $([math]::Round($elapsed, 2))s ($rate file ops/sec)" -ForegroundColor Green

    if ($iter -lt $Iterations) { Start-Sleep -Seconds 5 }
}

$avgTime = ($timings | Measure-Object -Average).Average

Add-ScenarioMetric -Key "loop_count" -Value $LoopCount
Add-ScenarioMetric -Key "iterations" -Value $Iterations
Add-ScenarioMetric -Key "avg_iteration_seconds" -Value ([math]::Round($avgTime, 2))
Add-ScenarioMetric -Key "avg_file_ops_per_sec" -Value ([math]::Round($LoopCount / $avgTime))
Add-ScenarioMetric -Key "total_file_operations" -Value $totalEvents
Add-ScenarioMetric -Key "expected_events" -Value "FILE_CREATED, FILE_RENAMED, FILE_DELETED, PROCESS_CREATED, MODULE_LOADED"
Add-ScenarioMetric -Key "estimated_event_count" -Value ($LoopCount * 3)

Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue

Complete-Scenario
