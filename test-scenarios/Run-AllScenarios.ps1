#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Orchestrator: Runs all test scenarios in sequence with pauses between them.

.DESCRIPTION
    This script replaces LoginVSI as the orchestration layer for now.
    It runs each scenario one at a time with configurable pauses between them,
    allowing Telegraf to capture clean per-scenario metrics in Grafana.

    When LoginVSI is available, this script can be replaced by LoginVSI workloads
    that call the individual Test-*.ps1 scripts. The scripts are designed to be
    self-contained and callable from any orchestrator.

    Each scenario:
      1. Switches the Telegraf scenario tag
      2. Runs the workload
      3. Saves results as JSON to C:\PerfTest\results\
      4. Pauses before the next scenario (for clean separation in graphs)

.PARAMETER PauseBetweenSeconds
    Seconds to pause between scenarios. Default: 60.
    This creates clear gaps in Grafana graphs between scenarios.

.PARAMETER SkipScenarios
    Array of scenario names to skip. E.g., @("browser_streaming", "driver_load")

.PARAMETER OnlyScenarios
    If specified, only run these scenarios. E.g., @("file_stress_loop", "registry_storm")

.EXAMPLE
    # Run all scenarios
    .\Run-AllScenarios.ps1

    # Run with shorter pauses
    .\Run-AllScenarios.ps1 -PauseBetweenSeconds 30

    # Run only file and registry tests
    .\Run-AllScenarios.ps1 -OnlyScenarios @("file_stress_loop", "registry_storm")

    # Run all except browser and driver (which may need special setup)
    .\Run-AllScenarios.ps1 -SkipScenarios @("browser_streaming", "driver_load")
#>

param(
    [int]$PauseBetweenSeconds = 60,
    [string[]]$SkipScenarios = @(),
    [string[]]$OnlyScenarios = @()
)

$ErrorActionPreference = "Stop"

# ---------- Scenario Registry ----------
# Each entry maps a friendly name to the script and its default parameters.
# This registry is the interface point for LoginVSI integration:
# each entry becomes a LoginVSI workload that calls the corresponding script.

$AllScenarios = [ordered]@{
    "idle_baseline" = @{
        Script = "Test-IdleBaseline.ps1"
        Params = @{ DurationMinutes = 10 }
        Description = "Idle baseline (10 min warmup)"
        RequiresAdmin = $false
    }
    "file_stress_loop" = @{
        Script = "Test-FileStressLoop.ps1"
        Params = @{ LoopCount = 1000; Iterations = 3 }
        Description = "File create/rename/delete loop"
        RequiresAdmin = $false
    }
    "registry_storm" = @{
        Script = "Test-RegistryStorm.ps1"
        Params = @{ LoopCount = 500; Iterations = 3 }
        Description = "Registry set/delete storm"
        RequiresAdmin = $false
    }
    "network_burst" = @{
        Script = "Test-NetworkBurst.ps1"
        Params = @{ RequestCount = 200; Iterations = 3 }
        Description = "HTTP request burst"
        RequiresAdmin = $false
    }
    "process_storm" = @{
        Script = "Test-ProcessStorm.ps1"
        Params = @{ ProcessCount = 200; Bursts = 3 }
        Description = "Rapid process spawn/terminate"
        RequiresAdmin = $false
    }
    "rpc_generation" = @{
        Script = "Test-RpcGeneration.ps1"
        Params = @{ QueryCount = 300; Iterations = 3 }
        Description = "WMI/RPC query loop"
        RequiresAdmin = $false
    }
    "service_cycle" = @{
        Script = "Test-ServiceCycle.ps1"
        Params = @{ Cycles = 10 }
        Description = "Service create/start/stop/delete"
        RequiresAdmin = $true
    }
    "user_account_modify" = @{
        Script = "Test-UserAccountModify.ps1"
        Params = @{ Cycles = 10 }
        Description = "User account create/modify/delete"
        RequiresAdmin = $true
    }
    "browser_streaming" = @{
        Script = "Test-BrowserStreaming.ps1"
        Params = @{ DurationSeconds = 300 }
        Description = "Browser streaming session (5 min)"
        RequiresAdmin = $false
    }
    "driver_load" = @{
        Script = "Test-DriverLoad.ps1"
        Params = @{ Cycles = 3 }
        Description = "Driver load via Defender restart"
        RequiresAdmin = $true
    }
    "zip_extraction" = @{
        Script = "Test-ZipExtraction.ps1"
        Params = @{ FileCount = 10000; Iterations = 3 }
        Description = "ZIP extraction workload"
        RequiresAdmin = $false
    }
    "file_storm" = @{
        Script = "Test-FileStorm.ps1"
        Params = @{ FileCount = 5000; Bursts = 3 }
        Description = "Mass file create/modify/delete bursts"
        RequiresAdmin = $false
    }
    "combined_high_density" = @{
        Script = "Test-CombinedHighDensity.ps1"
        Params = @{ DurationSeconds = 420 }
        Description = "All generators in parallel (7 min)"
        RequiresAdmin = $false
    }
    # NOTE: soak_test is excluded from Run-AllScenarios by default.
    # Run it separately: .\Run-SoakTest.ps1 -TotalHours 8
}

# ---------- Filter scenarios ----------
$scenariosToRun = [ordered]@{}

foreach ($name in $AllScenarios.Keys) {
    if ($OnlyScenarios.Count -gt 0 -and $name -notin $OnlyScenarios) { continue }
    if ($name -in $SkipScenarios) { continue }
    $scenariosToRun[$name] = $AllScenarios[$name]
}

# ---------- Pre-flight ----------
$scriptDir = $PSScriptRoot
$totalCount = $scenariosToRun.Count
$estimatedMinutes = [math]::Round(($totalCount * 5 + $totalCount * $PauseBetweenSeconds / 60), 0)

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Performance Test Suite - All Scenarios" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Host              : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  Scenarios         : $totalCount" -ForegroundColor White
Write-Host "  Pause between     : ${PauseBetweenSeconds}s" -ForegroundColor White
Write-Host "  Estimated runtime : ~${estimatedMinutes} minutes" -ForegroundColor White
Write-Host "  Results dir       : C:\PerfTest\results\" -ForegroundColor White
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Scenarios to run:" -ForegroundColor Yellow

$index = 0
foreach ($entry in $scenariosToRun.GetEnumerator()) {
    $index++
    $adminTag = if ($entry.Value.RequiresAdmin) { " [ADMIN]" } else { "" }
    Write-Host "  $index. $($entry.Key) - $($entry.Value.Description)$adminTag" -ForegroundColor White
}

Write-Host ""
Write-Host "Starting in 10 seconds... (Ctrl+C to cancel)" -ForegroundColor Yellow
Start-Sleep -Seconds 10

# ---------- Execute scenarios ----------
$suiteStart = Get-Date
$index = 0
$completedScenarios = @()
$failedScenarios = @()

foreach ($entry in $scenariosToRun.GetEnumerator()) {
    $index++
    $name = $entry.Key
    $config = $entry.Value

    Write-Host "`n" -ForegroundColor White
    Write-Host "########################################################" -ForegroundColor Magenta
    Write-Host " [$index / $totalCount] $name" -ForegroundColor Magenta
    Write-Host " $($config.Description)" -ForegroundColor Gray
    Write-Host "########################################################" -ForegroundColor Magenta

    $scriptPath = Join-Path $scriptDir $config.Script

    if (-not (Test-Path $scriptPath)) {
        Write-Host "[ERROR] Script not found: $scriptPath" -ForegroundColor Red
        $failedScenarios += $name
        continue
    }

    try {
        & $scriptPath @($config.Params)
        $completedScenarios += $name
    }
    catch {
        Write-Host "[ERROR] Scenario '$name' failed: $_" -ForegroundColor Red
        $failedScenarios += $name
    }

    # Pause between scenarios (except after the last one)
    if ($index -lt $totalCount) {
        Write-Host "`nPausing ${PauseBetweenSeconds}s before next scenario (clean separation in Grafana)..." -ForegroundColor Gray
        Start-Sleep -Seconds $PauseBetweenSeconds
    }
}

# ---------- Suite Summary ----------
$suiteEnd = Get-Date
$suiteDuration = ($suiteEnd - $suiteStart).TotalMinutes

Write-Host "`n" -ForegroundColor White
Write-Host "========================================================" -ForegroundColor Green
Write-Host " Test Suite COMPLETE" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  Duration   : $([math]::Round($suiteDuration, 1)) minutes" -ForegroundColor White
Write-Host "  Completed  : $($completedScenarios.Count) / $totalCount" -ForegroundColor White
if ($failedScenarios.Count -gt 0) {
    Write-Host "  Failed     : $($failedScenarios -join ', ')" -ForegroundColor Red
}
Write-Host ""
Write-Host "Results saved to: C:\PerfTest\results\" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open Grafana and set the time range to cover this test run" -ForegroundColor White
Write-Host "  2. Use the Scenario dropdown to compare metrics across scenarios" -ForegroundColor White
Write-Host "  3. Compare this host with the baseline host (Host dropdown)" -ForegroundColor White
Write-Host ""
Write-Host "To aggregate all JSON results:" -ForegroundColor Yellow
Write-Host "  Get-ChildItem C:\PerfTest\results\*.json | ForEach-Object { Get-Content `$_ | ConvertFrom-Json } | Format-Table scenario, duration_seconds" -ForegroundColor Gray
