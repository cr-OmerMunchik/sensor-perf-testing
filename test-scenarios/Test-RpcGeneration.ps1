<#
.SYNOPSIS
    Scenario 8: RPC Generation via WMI Calls

.DESCRIPTION
    Runs repeated WMI queries to generate RPC events.
    Generates: RPC_CALL, PROCESS_CREATED, MODULE_LOADED

    Good controlled RPC generation.

.PARAMETER QueryCount
    Number of WMI queries. Default: 300.

.PARAMETER Iterations
    Number of times to repeat. Default: 3.

.EXAMPLE
    .\Test-RpcGeneration.ps1
    .\Test-RpcGeneration.ps1 -QueryCount 1000
#>

param(
    [int]$QueryCount = 300,
    [int]$Iterations = 3
)

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "rpc_generation" `
    -Description "WMI/RPC query loop (${QueryCount} queries x ${Iterations} iterations)"

$timings = @()

for ($iter = 1; $iter -le $Iterations; $iter++) {
    Write-Host "Iteration $iter of $Iterations ($QueryCount WMI queries)..." -ForegroundColor White

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $QueryCount; $i++) {
        Get-CimInstance Win32_Process | Out-Null
        if ($i % 100 -eq 0) {
            Write-Host "  $i / $QueryCount queries..." -ForegroundColor Gray
        }
    }
    $sw.Stop()

    $elapsed = $sw.Elapsed.TotalSeconds
    $rate = [math]::Round($QueryCount / $elapsed, 1)
    $timings += $elapsed

    Write-Host "  $([math]::Round($elapsed, 2))s ($rate queries/sec)" -ForegroundColor Green

    if ($iter -lt $Iterations) { Start-Sleep -Seconds 5 }
}

$avgTime = ($timings | Measure-Object -Average).Average

Add-ScenarioMetric -Key "query_count_per_iteration" -Value $QueryCount
Add-ScenarioMetric -Key "iterations" -Value $Iterations
Add-ScenarioMetric -Key "avg_iteration_seconds" -Value ([math]::Round($avgTime, 2))
Add-ScenarioMetric -Key "avg_queries_per_sec" -Value ([math]::Round($QueryCount / $avgTime, 1))
Add-ScenarioMetric -Key "expected_events" -Value "RPC_CALL, PROCESS_CREATED, MODULE_LOADED"
Add-ScenarioMetric -Key "estimated_rpc_events" -Value $QueryCount

Complete-Scenario
