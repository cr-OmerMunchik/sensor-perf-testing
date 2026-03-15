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
$timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"

if ($NumCores -le 0) { $NumCores = [Environment]::ProcessorCount }
if (-not $ReportsDir) { $ReportsDir = "C:\PerfTest\reports" }

# ── Logging setup ──

$logsDir = "C:\PerfTest\logs"
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
$logFile = Join-Path $logsDir "perf-test-${timestamp}.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    switch ($Level) {
        "WARN"  { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        "ERROR" { Write-Host "[ERROR] $Message" -ForegroundColor Red }
        default {}
    }
}

Write-Log "=== Sensor Performance Test started ==="
Write-Log "Host: $env:COMPUTERNAME | OS: $([Environment]::OSVersion.VersionString)"
Write-Log "PowerShell: $($PSVersionTable.PSVersion) | User: $env:USERNAME"
Write-Log "Script: $PSCommandPath"
Write-Log "Parameters: HeavyMode=$HeavyMode EnableProfiling=$EnableProfiling NumCores=$NumCores"
Write-Log "Parameters: OnlyScenarios=[$($OnlyScenarios -join ',')] SkipScenarios=[$($SkipScenarios -join ',')]"
Write-Log "Parameters: SymbolsDir=$SymbolsDir ReportsDir=$ReportsDir ReportTag=$ReportTag"

$script:SensorProcessNames = @(
    "minionhost", "ActiveConsole", "CrsSvc", "PylumLoader", "AmSvc", "WscIfSvc",
    "ExecutionPreventionSvc", "ActiveCLIAgent", "CrAmTray", "Nnx", "CrEX3",
    "CybereasonAV", "CrDrvCtrl", "CrScanTool"
)

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
        Write-Log "wpr.exe not found. Install Windows Performance Toolkit for profiling. Continuing without profiling." -Level WARN
        $EnableProfiling = $false
    }
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        Write-Log ".NET SDK not found. ETL analysis requires .NET 8+. Install from https://dotnet.microsoft.com/download" -Level WARN
    } else {
        Write-Log ".NET SDK found: $(& dotnet --version 2>$null)"
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
Write-Host "  Log file      : $logFile" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ── Phase 1: Clear previous results ──

Write-Host "[Phase 1] Preparing environment..." -ForegroundColor Cyan
Write-Log "Phase 1: Preparing environment"

if (Test-Path $resultsDir) {
    $oldResults = Get-ChildItem $resultsDir -Filter "*.json" -ErrorAction SilentlyContinue
    if ($oldResults.Count -gt 0) {
        $backupDir = Join-Path $resultsDir "prev_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $oldResults | Move-Item -Destination $backupDir
        Write-Host "  Backed up $($oldResults.Count) previous result files to $backupDir" -ForegroundColor Gray
        Write-Log "Backed up $($oldResults.Count) previous result files to $backupDir"
    }
}
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
if ($EnableProfiling) {
    New-Item -ItemType Directory -Path $tracesDir -Force | Out-Null
    $oldTraces = Get-ChildItem $tracesDir -Filter "*.etl" -File -ErrorAction SilentlyContinue
    if ($oldTraces.Count -gt 0) {
        $oldTraceSize = [math]::Round(($oldTraces | Measure-Object Length -Sum).Sum / 1GB, 2)
        $oldTraces | Remove-Item -Force
        Write-Host "  Removed $($oldTraces.Count) old ETL traces ($oldTraceSize GB)" -ForegroundColor Gray
        Write-Log "Removed $($oldTraces.Count) old ETL traces ($oldTraceSize GB)"
    }
}
New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null

$freeSpace = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Write-Log "Disk space free (C:): ${freeSpace} GB"
if ($freeSpace -lt 2) {
    Write-Log "Low disk space (${freeSpace} GB free). ETL profiling requires 5-10 GB." -Level WARN
}

$sensorProcs = Get-Process -Name "minionhost","ActiveConsole" -ErrorAction SilentlyContinue
if ($sensorProcs) {
    Write-Log "Sensor processes running: $($sensorProcs | ForEach-Object { "$($_.Name) (PID $($_.Id))" } | Out-String -Stream | Where-Object { $_ })"
} else {
    Write-Log "No sensor processes detected (minionhost, ActiveConsole). Metrics will be empty." -Level WARN
}

# ── Phase 2: Run scenarios ──

Write-Host ""
Write-Host "[Phase 2] Running test scenarios..." -ForegroundColor Cyan
Write-Log "Phase 2: Running test scenarios"

$runArgs = @{
    CollectMetrics = $true
}
if (-not $HeavyMode)   { $runArgs["LightMode"] = $true }
if ($EnableProfiling)  { $runArgs["EnableProfiling"] = $true }
if ($OnlyScenarios.Count -gt 0)  { $runArgs["OnlyScenarios"] = $OnlyScenarios }
if ($SkipScenarios.Count -gt 0)  { $runArgs["SkipScenarios"] = $SkipScenarios }
if ($PauseBetweenSeconds -ge 0)  { $runArgs["PauseBetweenSeconds"] = $PauseBetweenSeconds }

$suiteStart = Get-Date
Write-Log "Scenario execution started at $($suiteStart.ToString('o'))"
& (Join-Path $scenariosDir "Run-AllScenarios.ps1") @runArgs
$suiteEnd = Get-Date
$suiteDurationMin = [math]::Round(($suiteEnd - $suiteStart).TotalMinutes, 1)

Write-Host ""
Write-Host "  Scenarios completed in $suiteDurationMin minutes." -ForegroundColor Green
Write-Log "Scenarios completed in $suiteDurationMin minutes"

if ($SkipReports) {
    Write-Host ""
    Write-Host "[DONE] Reports skipped. Results saved in $resultsDir" -ForegroundColor Yellow
    Write-Log "Reports skipped by user request. Results in $resultsDir"
    Write-Log "Log file: $logFile"
    exit 0
}

# ── Phase 3: Generate reports ──

Write-Host ""
Write-Host "[Phase 3] Generating reports..." -ForegroundColor Cyan
Write-Log "Phase 3: Generating reports"

Start-Sleep -Seconds 3
[GC]::Collect()

$resultFiles = Get-ChildItem $resultsDir -Filter "*.json" -File | Sort-Object Name
if ($resultFiles.Count -eq 0) {
    Write-Log "No scenario result JSON files found in $resultsDir. Skipping reports." -Level WARN
    Write-Log "Log file: $logFile"
    exit 0
}
Write-Host "  Found $($resultFiles.Count) scenario result files." -ForegroundColor Gray
Write-Log "Found $($resultFiles.Count) scenario result files: $($resultFiles.Name -join ', ')"

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
Write-Log "Generating performance report -> $perfReportPath"
& (Join-Path $toolsDir "generate-perf-report.ps1") @perfArgs
Write-Host "  Performance report: $perfReportPath" -ForegroundColor Green
Write-Log "Performance report written: $perfReportPath"

# --- ETL analysis report (if profiling was enabled) ---
if ($EnableProfiling) {
    $etlFiles = Get-ChildItem $tracesDir -Filter "*.etl" -File -ErrorAction SilentlyContinue
    if ($etlFiles.Count -gt 0) {
        Write-Host "  Found $($etlFiles.Count) ETL traces. Running analysis..." -ForegroundColor Gray
        Write-Log "Found $($etlFiles.Count) ETL traces: $($etlFiles.Name -join ', ')"

        $etlReportPath = Join-Path $ReportsDir "etl-cpu-hotspots-report-${timestamp}${tagSuffix}.html"

        if ($SymbolsDir -and (Test-Path $SymbolsDir)) {
            Write-Log "Scanning SymbolsDir for PDBs: $SymbolsDir"

            $allPdbs = Get-ChildItem $SymbolsDir -Recurse -Filter "*.pdb" -File
            Write-Log "Total PDB files found: $($allPdbs.Count)"

            # Validate: warn about renamed PDBs with _1, _2 suffixes (common when
            # files from different builds are dumped into a flat directory)
            $renamedPdbs = @($allPdbs | Where-Object { $_.BaseName -match '_\d+$' })
            if ($renamedPdbs.Count -gt 0) {
                $renamedSamples = ($renamedPdbs | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ", "
                Write-Log "Found $($renamedPdbs.Count) PDB files with _1/_2/_3 suffixes (e.g. $renamedSamples). These are likely renamed duplicates and will NOT match sensor binaries. If you copied PDBs from multiple builds into a flat directory, the symbol engine cannot resolve them." -Level WARN
                Write-Host "       Tip: Copy PDBs preserving the build output directory structure," -ForegroundColor Yellow
                Write-Host "       or keep only the PDBs from the exact build matching your installed sensor." -ForegroundColor Yellow
            }

            # Filter to directories containing sensor-relevant PDBs only.
            # _NT_SYMBOL_PATH is not recursive -- each directory must be listed explicitly.
            # A full build output may have 900+ PDBs across hundreds of directories,
            # exceeding the env var length limit. We only need the ~14 sensor modules.
            $sensorPdbDirs = @($allPdbs | Where-Object {
                $baseName = $_.BaseName
                $script:SensorProcessNames | Where-Object { $baseName -ieq $_ }
            } | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)

            $allPdbDirs = @($allPdbs | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
            Write-Log "PDB directories total: $($allPdbDirs.Count), sensor-relevant: $($sensorPdbDirs.Count)"

            if ($sensorPdbDirs.Count -gt 0) {
                $symbolPath = ($sensorPdbDirs -join ";") + ";SRV*C:\symbols*https://msdl.microsoft.com/download/symbols"
                $env:_NT_SYMBOL_PATH = $symbolPath
                Write-Host "  Symbol path set ($($sensorPdbDirs.Count) sensor PDB directories from $($allPdbDirs.Count) total)." -ForegroundColor Gray
                Write-Log "Symbol path set with $($sensorPdbDirs.Count) sensor PDB directories"
                foreach ($d in $sensorPdbDirs) { Write-Log "  PDB dir: $d" }

                # Check which sensor PDBs were found and which are missing
                $foundSensorPdbs = @($allPdbs | Where-Object {
                    $baseName = $_.BaseName
                    $script:SensorProcessNames | Where-Object { $baseName -ieq $_ }
                } | ForEach-Object { $_.BaseName.ToLower() } | Sort-Object -Unique)
                $missingSensorPdbs = @($script:SensorProcessNames | Where-Object { $_.ToLower() -notin $foundSensorPdbs })

                Write-Log "Sensor PDBs found: $($foundSensorPdbs -join ', ')"
                if ($missingSensorPdbs.Count -gt 0) {
                    Write-Log "Sensor PDBs missing (functions in these modules will show as hex addresses): $($missingSensorPdbs -join ', ')" -Level WARN
                }
            } else {
                Write-Log "No sensor-relevant PDBs found in $SymbolsDir. Looked for: $($script:SensorProcessNames -join ', '). Functions will appear as hex addresses." -Level WARN
                Write-Host "       The SymbolsDir does not contain PDBs matching sensor process names." -ForegroundColor Yellow
                Write-Host "       Expected PDB names: $($script:SensorProcessNames -join '.pdb, ').pdb" -ForegroundColor Yellow
            }
        } elseif ($SymbolsDir) {
            Write-Log "SymbolsDir not found: $SymbolsDir" -Level WARN
        }

        $useSymbols = [bool]$SymbolsDir

        $etlArgs = @{
            SkipInfluxDB       = $true
            SkipEtl            = $false
            OutputPath         = Join-Path $env:TEMP "perf-report-discard-$(Get-Date -Format 'yyyyMMddHHmmss').html"
            EtlOutputPath      = $etlReportPath
            NumCores           = $NumCores
            ScenarioResultsDir = $resultsDir
            TraceDir           = $tracesDir
        }
        if ($useSymbols)         { $etlArgs["UseSymbols"] = $true }
        if ($GenerateConfluence) { $etlArgs["GenerateConfluence"] = $true }

        Write-Log "Running ETL analysis -> $etlReportPath"
        & (Join-Path $toolsDir "generate-perf-report.ps1") @etlArgs
        Remove-Item $etlArgs.OutputPath -ErrorAction SilentlyContinue
        Remove-Item ([System.IO.Path]::ChangeExtension($etlArgs.OutputPath, "confluence.html")) -ErrorAction SilentlyContinue

        Write-Host "  ETL report: $etlReportPath" -ForegroundColor Green
        Write-Log "ETL report written: $etlReportPath"
    } else {
        Write-Log "No .etl files found in $tracesDir" -Level WARN
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
Write-Host "  Log            : $logFile" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Green

Write-Log "=== Run complete ==="
Write-Log "Duration: $suiteDurationMin minutes"
Write-Log "Reports: $(($reports | ForEach-Object { $_.Name }) -join ', ')"
Write-Log "Log file: $logFile"
