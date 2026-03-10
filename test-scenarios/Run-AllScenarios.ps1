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

.PARAMETER EnableProfiling
    If specified, captures a WPR trace for each scenario.
    Traces are saved to C:\PerfTest\traces\ (~200-500 MB per scenario).

.PARAMETER ProfilingProfiles
    WPR profiles to capture when profiling is enabled.
    Default: GeneralProfile, DiskIO
    Available: CPU, DiskIO, FileIO, Heap, GeneralProfile, Network

.EXAMPLE
    # Run all scenarios
    .\Run-AllScenarios.ps1

    # Run with shorter pauses
    .\Run-AllScenarios.ps1 -PauseBetweenSeconds 30

    # Run only file and registry tests
    .\Run-AllScenarios.ps1 -OnlyScenarios @("file_stress_loop", "registry_storm")

    # Run all except browser and driver (which may need special setup)
    .\Run-AllScenarios.ps1 -SkipScenarios @("browser_streaming", "driver_load")

    # Run with WPR profiling enabled
    .\Run-AllScenarios.ps1 -EnableProfiling -OnlyScenarios @("file_storm", "combined_high_density")

    # Run with custom WPR profiles
    .\Run-AllScenarios.ps1 -EnableProfiling -ProfilingProfiles @("CPU", "FileIO", "Heap")
#>

param(
    [int]$PauseBetweenSeconds = -1,
    [string[]]$SkipScenarios = @(),
    [string[]]$OnlyScenarios = @(),
    [switch]$EnableProfiling,
    [string[]]$ProfilingProfiles = @("GeneralProfile", "DiskIO"),
    [switch]$LightMode
)

$ErrorActionPreference = "Stop"

# ---------- Scenario Registry ----------
# Each entry maps a friendly name to the script and its default parameters.
# This registry is the interface point for LoginVSI integration:
# each entry becomes a LoginVSI workload that calls the corresponding script.

$AllScenarios = [ordered]@{
    "idle_baseline" = @{
        Script = "Test-IdleBaseline.ps1"
        Params = @{ DurationMinutes = 15 }
        Description = "Idle baseline (15 min)"
        RequiresAdmin = $false
    }
    "registry_storm" = @{
        Script = "Test-RegistryStorm.ps1"
        Params = @{ LoopCount = 2000; Iterations = 100 }
        Description = "Registry set/delete storm (~12 min)"
        RequiresAdmin = $false
    }
    "network_burst" = @{
        Script = "Test-NetworkBurst.ps1"
        Params = @{ RequestCount = 300; Iterations = 50 }
        Description = "HTTP request burst (~15 min)"
        RequiresAdmin = $false
    }
    "process_storm" = @{
        Script = "Test-ProcessStorm.ps1"
        Params = @{ ProcessCount = 100; Bursts = 30 }
        Description = "Rapid process spawn/terminate (~13 min)"
        RequiresAdmin = $false
    }
    "rpc_generation" = @{
        Script = "Test-RpcGeneration.ps1"
        Params = @{ QueryCount = 500; Iterations = 25 }
        Description = "WMI/RPC query loop (~15 min)"
        RequiresAdmin = $false
    }
    "service_cycle" = @{
        Script = "Test-ServiceCycle.ps1"
        Params = @{ Cycles = 200 }
        Description = "Service create/start/stop/delete (~7 min)"
        RequiresAdmin = $true
    }
    "user_account_modify" = @{
        Script = "Test-UserAccountModify.ps1"
        Params = @{ Cycles = 200 }
        Description = "User account create/modify/delete (~5 min)"
        RequiresAdmin = $true
    }
    "browser_streaming" = @{
        Script = "Test-BrowserStreaming.ps1"
        Params = @{ DurationSeconds = 900 }
        Description = "Browser streaming session (15 min)"
        RequiresAdmin = $false
    }
    "driver_load" = @{
        Script = "Test-DriverLoad.ps1"
        Params = @{ Cycles = 10 }
        Description = "Driver load via Defender restart (~3 min)"
        RequiresAdmin = $true
    }
    "file_stress_loop" = @{
        Script = "Test-FileStressLoop.ps1"
        Params = @{ LoopCount = 5000; Iterations = 100 }
        Description = "File create/rename/delete loop (~14 min)"
        RequiresAdmin = $false
    }
    "zip_extraction" = @{
        Script = "Test-ZipExtraction.ps1"
        Params = @{ FileCount = 10000; Iterations = 10 }
        Description = "ZIP extraction workload (~12 min)"
        RequiresAdmin = $false
    }
    "file_storm" = @{
        Script = "Test-FileStorm.ps1"
        Params = @{ FileCount = 10000; Bursts = 30 }
        Description = "Mass file create/modify/delete bursts (~12 min)"
        RequiresAdmin = $false
    }
    "combined_high_density" = @{
        Script = "Test-CombinedHighDensity.ps1"
        Params = @{ DurationSeconds = 900 }
        Description = "All generators in parallel (15 min)"
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

# ---------- Light mode overrides ----------
# Reduced workloads for small 2-core VMs where NNX + sensor saturate CPU.
# Target: each scenario ~2-4 min, full suite < 90 min including pauses.
if ($LightMode) {
    $LightOverrides = @{
        "idle_baseline"        = @{ Params = @{ DurationMinutes = 5 };                                               Description = "Idle baseline (5 min)" }
        "registry_storm"       = @{ Params = @{ LoopCount = 200; Iterations = 10 };                                  Description = "Registry set/delete storm - light (~2 min)" }
        "network_burst"        = @{ Params = @{ RequestCount = 50; Iterations = 10 };                                 Description = "HTTP request burst - light (~2 min)" }
        "process_storm"        = @{ Params = @{ ProcessCount = 30; Bursts = 10 };                                     Description = "Rapid process spawn/terminate - light (~3 min)" }
        "rpc_generation"       = @{ Params = @{ QueryCount = 100; Iterations = 10 };                                  Description = "WMI/RPC query loop - light (~2 min)" }
        "service_cycle"        = @{ Params = @{ Cycles = 20 };                                                        Description = "Service create/start/stop/delete - light (~2 min)" }
        "user_account_modify"  = @{ Params = @{ Cycles = 20 };                                                        Description = "User account create/modify/delete - light (~1 min)" }
        "browser_streaming"    = @{ Params = @{ DurationSeconds = 180 };                                              Description = "Browser streaming session - light (3 min)" }
        "driver_load"          = @{ Params = @{ Cycles = 3 };                                                         Description = "Driver load via Defender restart - light (~1 min)" }
        "file_stress_loop"     = @{ Params = @{ LoopCount = 500; Iterations = 5 };                                    Description = "File create/rename/delete loop - light (~3 min)" }
        "zip_extraction"       = @{ Params = @{ FileCount = 2000; Iterations = 3 };                                   Description = "ZIP extraction workload - light (~3 min)" }
        "file_storm"           = @{ Params = @{ FileCount = 2000; Bursts = 5 };                                       Description = "Mass file create/modify/delete bursts - light (~3 min)" }
        "combined_high_density" = @{ Params = @{ DurationSeconds = 300; FileLoopCount = 200; RegistryLoopCount = 200; NetworkRequestCount = 50 }; Description = "All generators in parallel - light (5 min)" }
    }
    foreach ($name in @($scenariosToRun.Keys)) {
        if ($LightOverrides.ContainsKey($name)) {
            $scenariosToRun[$name].Params = $LightOverrides[$name].Params
            $scenariosToRun[$name].Description = $LightOverrides[$name].Description
        }
    }
    if ($PauseBetweenSeconds -eq -1) { $PauseBetweenSeconds = 30 }
    Write-Host "[LIGHT MODE] Reduced workloads for small VMs" -ForegroundColor Yellow
}

if ($PauseBetweenSeconds -eq -1) { $PauseBetweenSeconds = 60 }

# ---------- Enable profiling if requested ----------
$scriptDir = $PSScriptRoot
. "$scriptDir\ScenarioHelpers.ps1"

if ($EnableProfiling) {
    Enable-Profiling -Profiles $ProfilingProfiles
}
else {
    $env:PERF_TEST_PROFILING = "0"
    Remove-Item Env:PERF_TEST_PROFILING_PROFILES -ErrorAction SilentlyContinue
}

# ---------- Pre-flight ----------
$totalCount = $scenariosToRun.Count
$estimatedMinutes = [math]::Round(($totalCount * 13 + $totalCount * $PauseBetweenSeconds / 60), 0)

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Performance Test Suite - All Scenarios" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Host              : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  Scenarios         : $totalCount" -ForegroundColor White
Write-Host "  Pause between     : ${PauseBetweenSeconds}s" -ForegroundColor White
Write-Host "  Estimated runtime : ~${estimatedMinutes} minutes" -ForegroundColor White
Write-Host "  Results dir       : C:\PerfTest\results\" -ForegroundColor White
if ($EnableProfiling) {
    $estTraceGB = [math]::Round($totalCount * 0.35, 1)
    Write-Host "  Profiling         : ON ($($ProfilingProfiles -join ', '))" -ForegroundColor Yellow
    Write-Host "  Traces dir        : C:\PerfTest\traces\" -ForegroundColor White
    Write-Host "  Est. trace size   : ~${estTraceGB} GB total" -ForegroundColor White
}
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
        $params = $config.Params
        & $scriptPath @params
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
if ($EnableProfiling) {
    Write-Host "  4. Collect traces: .\Collect-Traces.ps1 (from your workstation)" -ForegroundColor White
    Write-Host "  5. Open .etl files in WPA to analyze CPU/IO hotspots" -ForegroundColor White
}
Write-Host ""
Write-Host "To aggregate all JSON results:" -ForegroundColor Yellow
Write-Host "  Get-ChildItem C:\PerfTest\results\*.json | ForEach-Object { Get-Content `$_ | ConvertFrom-Json } | Format-Table scenario, duration_seconds" -ForegroundColor Gray
