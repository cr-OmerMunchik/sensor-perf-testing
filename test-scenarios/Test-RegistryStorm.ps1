<#
.SYNOPSIS
    Scenario 3: Registry Storm (Clean Signal)

.DESCRIPTION
    Creates and deletes registry values in a tight loop.
    Generates: REGISTRY_VALUE_SET, REGISTRY_VALUE_DELETED,
    PROCESS_CREATED, MODULE_LOADED

    Clean signal, easy to control event rate.

.PARAMETER LoopCount
    Number of set/delete cycles. Default: 500.

.PARAMETER Iterations
    Number of times to repeat. Default: 3.

.EXAMPLE
    .\Test-RegistryStorm.ps1
    .\Test-RegistryStorm.ps1 -LoopCount 2000
#>

param(
    [int]$LoopCount = 500,
    [int]$Iterations = 3
)

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "registry_storm" `
    -Description "Registry set/delete loop (${LoopCount} values x ${Iterations} iterations)"

$regPath = "HKCU:\Software\PerfTest_RegistryStorm"

# Ensure the key exists
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

$timings = @()

for ($iter = 1; $iter -le $Iterations; $iter++) {
    Write-Host "Iteration $iter of $Iterations ($LoopCount values)..." -ForegroundColor White

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $LoopCount; $i++) {
        New-ItemProperty -Path $regPath -Name "Val$i" -Value "testdata_$i" -PropertyType String -Force | Out-Null
        Remove-ItemProperty -Path $regPath -Name "Val$i" -ErrorAction SilentlyContinue
    }
    $sw.Stop()

    $elapsed = $sw.Elapsed.TotalSeconds
    $rate = [math]::Round(($LoopCount * 2) / $elapsed)
    $timings += $elapsed

    Write-Host "  $([math]::Round($elapsed, 2))s ($rate reg ops/sec)" -ForegroundColor Green

    if ($iter -lt $Iterations) { Start-Sleep -Seconds 5 }
}

$avgTime = ($timings | Measure-Object -Average).Average

Add-ScenarioMetric -Key "loop_count" -Value $LoopCount
Add-ScenarioMetric -Key "iterations" -Value $Iterations
Add-ScenarioMetric -Key "avg_iteration_seconds" -Value ([math]::Round($avgTime, 2))
Add-ScenarioMetric -Key "avg_reg_ops_per_sec" -Value ([math]::Round(($LoopCount * 2) / $avgTime))
Add-ScenarioMetric -Key "expected_events" -Value "REGISTRY_VALUE_SET, REGISTRY_VALUE_DELETED, PROCESS_CREATED, MODULE_LOADED"
Add-ScenarioMetric -Key "estimated_event_count" -Value ($LoopCount * 2)

# Cleanup
Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue

Complete-Scenario
