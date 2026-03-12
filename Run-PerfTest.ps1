#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Single entry-point for running performance tests and generating reports.

.DESCRIPTION
    Runs the scenario suite with inline metrics collection, optionally with ETL profiling,
    then generates performance and ETL analysis reports.

    This is the recommended way to run performance tests on any VM or local machine.

    By default the script runs in Light mode (reduced workloads, ~45 min).
    Use -HeavyMode for the full workload suite (~3 hours).

.PARAMETER HeavyMode
    Run full workloads instead of the default light workloads.
    Recommended only for machines with 4+ cores.

.PARAMETER EnableProfiling
    Capture WPR/ETL traces per scenario for CPU hotspot analysis.
    Requires wpr.exe (Windows Performance Toolkit).

.PARAMETER OnlyScenarios
    Run only these scenarios. E.g., @("file_stress_loop", "registry_storm")

.PARAMETER SkipScenarios
    Skip these scenarios. E.g., @("browser_streaming", "driver_load")

.PARAMETER PauseBetweenSeconds
    Seconds to pause between scenarios. Default: 30 (light) or 60 (heavy).

.PARAMETER SkipReports
    Skip report generation after scenarios complete.

.PARAMETER NumCores
    Number of CPU cores on the test machine (for CPU% calculations). Auto-detected if omitted.

.PARAMETER ReportsDir
    Directory to write reports to. Default: C:\PerfTest\reports

.PARAMETER SymbolsDir
    Path to PDB symbol files for ETL function name resolution. If not provided, functions
    appear as hex addresses.

.PARAMETER GenerateConfluence
    Also generate Confluence-compatible HTML reports.

.PARAMETER ReportTag
    Optional tag appended to report filenames (e.g., "v26.1.30.1" produces
    sensor-perf-report-2026-02-22-v26.1.30.1.html).

.EXAMPLE
    # Default run (light mode, ~45 min)
    .\Run-PerfTest.ps1

.EXAMPLE
    # Heavy-mode run with profiling and Confluence output
    .\Run-PerfTest.ps1 -HeavyMode -EnableProfiling -GenerateConfluence

.EXAMPLE
    # Specific scenarios only, with symbols for ETL profiling
    .\Run-PerfTest.ps1 -EnableProfiling `
        -OnlyScenarios @("file_stress_loop","process_storm","combined_high_density") `
        -SymbolsDir "C:\Symbols\v26.1.30.1"

.EXAMPLE
    # Just regenerate reports from a previous run's results
    .\Run-PerfTest.ps1 -SkipScenarios @("*") -NumCores 2
#>

param(
    [switch]$HeavyMode,
    [switch]$EnableProfiling,
    [string[]]$OnlyScenarios = @(),
    [string[]]$SkipScenarios = @(),
    [int]$PauseBetweenSeconds = -1,
    [switch]$SkipReports,
    [int]$NumCores = 0,
    [string]$ReportsDir,
    [string]$SymbolsDir,
    [switch]$GenerateConfluence,
    [string]$ReportTag
)

$ErrorActionPreference = "Stop"
$baseDir = $PSScriptRoot
$scenariosDir = Join-Path $baseDir "test-scenarios"
$toolsDir = Join-Path $baseDir "tools"
$resultsDir = "C:\PerfTest\results"
$tracesDir = "C:\PerfTest\traces"
$timestamp = Get-Date -Format "yyyy-MM-dd"

if ($NumCores -le 0) { $NumCores = [Environment]::ProcessorCount }
if (-not $ReportsDir) { $ReportsDir = "C:\PerfTest\reports" }

# ── Preflight checks ──

if (-not (Test-Path $scenariosDir)) {
    throw "Scenarios directory not found: $scenariosDir. Are you running from the repo root?"
}
if (-not (Test-Path (Join-Path $scenariosDir "Run-AllScenarios.ps1"))) {
    throw "Run-AllScenarios.ps1 not found in $scenariosDir"
}

if ($EnableProfiling) {
    $wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
    if (-not $wpr) {
        Write-Host "[WARN] wpr.exe not found. Install Windows Performance Toolkit for profiling." -ForegroundColor Yellow
        Write-Host "       Continuing without profiling." -ForegroundColor Yellow
        $EnableProfiling = $false
    }
}

# ── Print banner ──

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Sensor Performance Test - Self-Service Runner" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Host          : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  Cores         : $NumCores" -ForegroundColor White
Write-Host "  Mode          : $(if ($HeavyMode) { 'HEAVY' } else { 'LIGHT (default)' })" -ForegroundColor White
Write-Host "  Profiling     : $(if ($EnableProfiling) { 'YES (WPR)' } else { 'NO' })" -ForegroundColor White
Write-Host "  Metrics       : YES (inline WPC, 5s interval)" -ForegroundColor White
Write-Host "  Reports dir   : $ReportsDir" -ForegroundColor White
if ($SymbolsDir) {
    Write-Host "  Symbols dir   : $SymbolsDir" -ForegroundColor White
}
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ── Phase 1: Clear previous results ──

Write-Host "[Phase 1] Preparing environment..." -ForegroundColor Cyan

if (Test-Path $resultsDir) {
    $oldResults = Get-ChildItem $resultsDir -Filter "*.json" -ErrorAction SilentlyContinue
    if ($oldResults.Count -gt 0) {
        $backupDir = Join-Path $resultsDir "prev_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $oldResults | Move-Item -Destination $backupDir
        Write-Host "  Backed up $($oldResults.Count) previous result files to $backupDir" -ForegroundColor Gray
    }
}
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
if ($EnableProfiling) {
    New-Item -ItemType Directory -Path $tracesDir -Force | Out-Null
}
New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null

# ── Phase 2: Run scenarios ──

Write-Host ""
Write-Host "[Phase 2] Running test scenarios..." -ForegroundColor Cyan

$runArgs = @{
    CollectMetrics = $true
}
if (-not $HeavyMode)   { $runArgs["LightMode"] = $true }
if ($EnableProfiling)  { $runArgs["EnableProfiling"] = $true }
if ($OnlyScenarios.Count -gt 0)  { $runArgs["OnlyScenarios"] = $OnlyScenarios }
if ($SkipScenarios.Count -gt 0)  { $runArgs["SkipScenarios"] = $SkipScenarios }
if ($PauseBetweenSeconds -ge 0)  { $runArgs["PauseBetweenSeconds"] = $PauseBetweenSeconds }

$suiteStart = Get-Date
& (Join-Path $scenariosDir "Run-AllScenarios.ps1") @runArgs
$suiteEnd = Get-Date
$suiteDurationMin = [math]::Round(($suiteEnd - $suiteStart).TotalMinutes, 1)

Write-Host ""
Write-Host "  Scenarios completed in $suiteDurationMin minutes." -ForegroundColor Green

if ($SkipReports) {
    Write-Host ""
    Write-Host "[DONE] Reports skipped. Results saved in $resultsDir" -ForegroundColor Yellow
    exit 0
}

# ── Phase 3: Generate reports ──

Write-Host ""
Write-Host "[Phase 3] Generating reports..." -ForegroundColor Cyan

$resultFiles = Get-ChildItem $resultsDir -Filter "*.json" -File | Sort-Object Name
if ($resultFiles.Count -eq 0) {
    Write-Host "[WARN] No scenario result JSON files found in $resultsDir. Skipping reports." -ForegroundColor Yellow
    exit 0
}
Write-Host "  Found $($resultFiles.Count) scenario result files." -ForegroundColor Gray

$tagSuffix = if ($ReportTag) { "-$ReportTag" } else { "" }

# --- Performance report (from scenario JSONs) ---
$perfReportPath = Join-Path $ReportsDir "sensor-perf-report-${timestamp}${tagSuffix}.html"

$perfArgs = @{
    ScenarioResultsDir = $resultsDir
    NumCores           = $NumCores
    OutputPath         = $perfReportPath
    SkipInfluxDB       = $true
    SkipEtl            = $true
}
if (-not $HeavyMode)     { $perfArgs["LightMode"] = $true }
if ($GenerateConfluence) { $perfArgs["GenerateConfluence"] = $true }

Write-Host "  Generating performance report..." -ForegroundColor Gray
& (Join-Path $toolsDir "generate-perf-report.ps1") @perfArgs
Write-Host "  Performance report: $perfReportPath" -ForegroundColor Green

# --- ETL analysis report (if profiling was enabled) ---
if ($EnableProfiling) {
    $etlFiles = Get-ChildItem $tracesDir -Filter "*.etl" -File -ErrorAction SilentlyContinue
    if ($etlFiles.Count -gt 0) {
        Write-Host "  Found $($etlFiles.Count) ETL traces. Running analysis..." -ForegroundColor Gray

        $etlReportPath = Join-Path $ReportsDir "etl-cpu-hotspots-report-${timestamp}${tagSuffix}.html"

        if ($SymbolsDir -and (Test-Path $SymbolsDir)) {
            $pdbPaths = Get-ChildItem $SymbolsDir -Recurse -Filter "*.pdb" -File |
                ForEach-Object { $_.DirectoryName } | Sort-Object -Unique
            if ($pdbPaths.Count -gt 0) {
                $symbolPath = ($pdbPaths -join ";") + ";SRV*C:\symbols*https://msdl.microsoft.com/download/symbols"
                $env:_NT_SYMBOL_PATH = $symbolPath
                Write-Host "  Symbol path set ($($pdbPaths.Count) PDB directories)." -ForegroundColor Gray
            }
        }

        $useSymbols = [bool]$SymbolsDir

        $etlArgs = @{
            SkipInfluxDB       = $true
            SkipEtl            = $false
            OutputPath         = Join-Path $env:TEMP "perf-report-discard-$(Get-Date -Format 'yyyyMMddHHmmss').html"
            EtlOutputPath      = $etlReportPath
            NumCores           = $NumCores
            ScenarioResultsDir = $resultsDir
        }
        if ($useSymbols)         { $etlArgs["UseSymbols"] = $true }
        if ($GenerateConfluence) { $etlArgs["GenerateConfluence"] = $true }

        & (Join-Path $toolsDir "generate-perf-report.ps1") @etlArgs
        Remove-Item $etlArgs.OutputPath -ErrorAction SilentlyContinue
        Remove-Item ([System.IO.Path]::ChangeExtension($etlArgs.OutputPath, "confluence.html")) -ErrorAction SilentlyContinue

        Write-Host "  ETL report: $etlReportPath" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] No .etl files found in $tracesDir" -ForegroundColor Yellow
    }
}

# ── Summary ──

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  ALL DONE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Duration       : $suiteDurationMin minutes" -ForegroundColor White
Write-Host "  Results        : $resultsDir" -ForegroundColor White
Write-Host "  Reports        : $ReportsDir" -ForegroundColor White

$reports = Get-ChildItem $ReportsDir -Filter "*${timestamp}${tagSuffix}*" -File -ErrorAction SilentlyContinue
foreach ($r in $reports) {
    Write-Host "    - $($r.Name)" -ForegroundColor White
}

if ($EnableProfiling) {
    $traceSize = [math]::Round(($etlFiles | Measure-Object Length -Sum).Sum / 1GB, 2)
    Write-Host "  Traces         : $tracesDir ($($etlFiles.Count) files, ${traceSize} GB)" -ForegroundColor White
}
Write-Host "================================================================" -ForegroundColor Green
