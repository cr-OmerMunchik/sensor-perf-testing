<#
.SYNOPSIS
    Generates a separate report listing Top 5 Sensor Processes only.
    Uses ALL processes from the trace (not just top 10), filters to sensor processes,
    and picks the test with highest CPU usage.

.PARAMETER TraceDir
    Path to directory containing .etl trace files.

.PARAMETER InfluxJsonPath
    Path to pre-fetched InfluxDB JSON (for scenario selection).

.PARAMETER OutputPath
    Output file. Default: sensor-processes-report-YYYYMMDD.md
#>

[CmdletBinding()]
param(
    [string]$TraceDir,
    [string]$InfluxJsonPath,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir = Split-Path -Parent $scriptDir

$traceDirs = @(
    "C:\Users\OmerMunchik\playground\traces\2026-02-23",
    (Join-Path $toolsDir "fresh-traces\2026-02-23"),
    (Join-Path $toolsDir "playground\traces\2026-02-23")
)
if (-not $TraceDir) {
    foreach ($d in $traceDirs) {
        if ((Test-Path $d) -and (Get-ChildItem $d -Filter "*.etl" -ErrorAction SilentlyContinue)) {
            $TraceDir = $d; break
        }
    }
    if (-not $TraceDir) { $TraceDir = $traceDirs[1] }
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $toolsDir "sensor-processes-report-$(Get-Date -Format 'yyyyMMdd').md"
}

# --- Load InfluxDB data for scenario selection ---
$influxData = $null
$defaultInfluxPath = Join-Path $toolsDir "influx-data-fresh.json"
if (-not $InfluxJsonPath -and (Test-Path $defaultInfluxPath)) { $InfluxJsonPath = $defaultInfluxPath }
if ($InfluxJsonPath -and (Test-Path $InfluxJsonPath)) {
    Write-Host "Using InfluxDB data from: $InfluxJsonPath" -ForegroundColor Cyan
    $influxData = Get-Content $InfluxJsonPath -Raw | ConvertFrom-Json
}

# Pick scenario with highest CPU (TEST-PERF-3 = sensor VM)
$scenario = $null
if ($influxData -and $influxData.sensorCpu) {
    $worst = $influxData.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-3" } | Sort-Object { $_.peakCpu } -Descending | Select-Object -First 1
    if ($worst) {
        $scenario = $worst.scenario
        $peakCpu = [math]::Round($worst.peakCpu, 0)
        Write-Host "Using highest CPU scenario: $scenario ($peakCpu% peak)" -ForegroundColor Cyan
    }
}
if (-not $scenario) { $scenario = "combined_high_density" }

# Ensure TraceDir has traces for this scenario
$checkDirs = @("C:\Users\OmerMunchik\playground\traces\2026-02-23", (Join-Path $toolsDir "fresh-traces\2026-02-23"))
foreach ($d in $checkDirs) {
    if (Test-Path $d) {
        $hasScenario = Get-ChildItem $d -Filter "*.etl" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$scenario*" }
        if ($hasScenario) { $TraceDir = $d; break }
    }
}

# --- Run ETL with ALL processes (--top-processes 0) ---
$etlData = $null
$etlProject = Join-Path $scriptDir "etl-analyzer\EtlAnalyzer.csproj"
$matchingTraces = @(Get-ChildItem $TraceDir -Filter "*.etl" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$scenario*" })
if ($matchingTraces.Count -gt 0 -and (Test-Path $etlProject)) {
    Write-Host "Analyzing ETL trace for $scenario (all processes, no symbols)..." -ForegroundColor Cyan
    $etlJson = Join-Path $env:TEMP "sensor-proc-etl-$(Get-Date -Format 'yyyyMMddHHmmss').json"
    try {
        $etlArgs = @("run", "--project", $etlProject, "--", $TraceDir, "--scenario", $scenario, "--limit", "1", "--top-processes", "0")
        $ErrorActionPreferencePrev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $etlOutput = & dotnet @etlArgs 2>&1 | Out-String
        $ErrorActionPreference = $ErrorActionPreferencePrev
        $etlOutput | Out-File $etlJson -Encoding utf8
        $jsonMatch = [regex]::Match((Get-Content $etlJson -Raw), '\{\s*"traces"\s*:[\s\S]*\}')
        if ($jsonMatch.Success) { $etlData = $jsonMatch.Value | ConvertFrom-Json }
    } catch {
        Write-Warning "ETL analysis failed: $_"
    }
    Remove-Item $etlJson -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "No traces for $scenario in $TraceDir" -ForegroundColor Yellow
}

# --- Build report ---
$sensorProcessNames = @("minionhost", "ActiveConsole", "CrsSvc", "PylumLoader", "AmSvc", "WscIfSvc", "ExecutionPreventionSvc", "ActiveCLIAgent", "CrAmTray", "Nnx", "CrEX3", "CybereasonAV", "CrDrvCtrl", "CrScanTool")

$processRoles = @{
    minionhost = "ActiveProbe sensor core; handles telemetry, policy, and agent logic"
    ActiveConsole = "Sensor UI component"
    CrsSvc = "Core sensor service"
    PylumLoader = "Sensor loader component"
    AmSvc = "Anti-malware service"
    WscIfSvc = "Windows Security Center interface"
    ExecutionPreventionSvc = "Execution prevention service"
    ActiveCLIAgent = "CLI agent component"
    CrAmTray = "System tray component"
    Nnx = "Sensor core module"
    CrEX3 = "Sensor extension"
    CybereasonAV = "Anti-virus component"
    CrDrvCtrl = "Driver control"
    CrScanTool = "Scan utility"
}

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# Top 5 Sensor Processes Report")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("**Test:** $scenario (highest CPU usage) | **Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("*This report lists the top 5 sensor processes by CPU usage. All processes in the trace were analyzed (not limited to top 10 overall).*")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

$trace = $null
if ($etlData -and $etlData.traces -and $etlData.traces.Count -gt 0) {
    $trace = $etlData.traces | Where-Object { $_.scenario -eq $scenario -and -not $_.error } | Select-Object -First 1
    if (-not $trace) { $trace = $etlData.traces | Where-Object { -not $_.error } | Select-Object -First 1 }
}

if ($trace -and ($trace.topProcesses -or $trace.TopProcesses)) {
    $procList = @($trace.topProcesses)
    if (-not $procList -or $procList.Count -eq 0) { $procList = @($trace.TopProcesses) }
    $sensorProcs = @($procList | Where-Object {
        $pn = $_.process; if (-not $pn) { $pn = $_.Process }
        $pn -and ($sensorProcessNames -contains $pn)
    } | Select-Object -First 5)

    [void]$sb.AppendLine("## Top 5 Sensor Processes (by CPU)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Process | Role | CPU time (ms) | Percent |")
    [void]$sb.AppendLine("|---------|------|---------------|---------|")
    if ($sensorProcs.Count -gt 0) {
        foreach ($p in $sensorProcs) {
            $role = if ($processRoles[$p.process]) { $processRoles[$p.process] } else { "Sensor component" }
            [void]$sb.AppendLine("| $($p.process) | $role | $($p.weightMs) | $($p.percent)% |")
        }
    } else {
        [void]$sb.AppendLine("| *(no sensor processes found in this trace)* | - | - | - |")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("*Percent = share of total CPU samples collected during the trace (all cores).*")
} else {
    [void]$sb.AppendLine("## Top 5 Sensor Processes")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("*No trace data available for $scenario.*")
}

$report = $sb.ToString()

# Backup before writing
if (Test-Path $OutputPath) {
    $backupPath = Join-Path (Split-Path $OutputPath) "sensor-processes-report-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
    Copy-Item $OutputPath $backupPath -Force
    Write-Host "Backed up previous report to: $backupPath" -ForegroundColor Cyan
}

$report | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Sensor processes report written to: $OutputPath" -ForegroundColor Green
