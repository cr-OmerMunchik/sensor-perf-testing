<#
.SYNOPSIS
    Generates a short, VP-ready executive summary for sensor performance.

.DESCRIPTION
    Picks the single worst test scenario, compares VM3 (sensor) vs VM4 (no sensor),
    and shows CPU, memory, top processes, and bottleneck functions. Uses symbols for readable names.
    Designed for a 5-minute VP R&D presentation.

.PARAMETER TraceDir
    Path to directory containing .etl trace files.

.PARAMETER InfluxJsonPath
    Path to pre-fetched InfluxDB JSON. Required if workstation cannot reach InfluxDB.

.PARAMETER Token
    InfluxDB token (for direct fetch). Uses $env:INFLUXDB_TOKEN if not set.

.PARAMETER OutputPath
    Output file. Default: executive-summary-YYYYMMDD.md
#>

[CmdletBinding()]
param(
    [string]$TraceDir,
    [string]$InfluxJsonPath,
    [string]$Token = $env:INFLUXDB_TOKEN,
    [string]$OutputPath,
    [string]$Scenario  # Force scenario (e.g. user_account_modify) to skip scan; use when sensor dominates
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
    $OutputPath = Join-Path $toolsDir "executive-summary-$(Get-Date -Format 'yyyyMMdd').md"
}

# --- Load InfluxDB data ---
$influxData = $null
$defaultInfluxPath = Join-Path $toolsDir "influx-data-fresh.json"
if (-not $InfluxJsonPath -and (Test-Path $defaultInfluxPath)) { $InfluxJsonPath = $defaultInfluxPath }
if ($InfluxJsonPath -and (Test-Path $InfluxJsonPath)) {
    Write-Host "Using InfluxDB data from: $InfluxJsonPath" -ForegroundColor Cyan
    $influxData = Get-Content $InfluxJsonPath -Raw | ConvertFrom-Json
} elseif ($Token) {
    $influxJson = Join-Path $env:TEMP "exec-influx-$(Get-Date -Format 'yyyyMMddHHmmss').json"
    $influxScript = Join-Path $scriptDir "influx-analyze.ps1"
    if (Test-Path $influxScript) {
        Write-Host "Fetching InfluxDB data..." -ForegroundColor Cyan
        & $influxScript -Token $Token -InfluxUrl "http://172.46.16.24:8086" -OutputPath $influxJson 2>&1 | Out-Null
        if (Test-Path $influxJson) {
            $influxData = Get-Content $influxJson -Raw | ConvertFrom-Json
            Remove-Item $influxJson -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Pick scenario: prefer one where sensor processes dominate (minionhost, ActiveConsole in top 3) ---
$scenario = $null
$vm3SensorCpu = $null
$vm4SensorCpu = $null
$vm3SysCpu = $null
$vm4SysCpu = $null
$vm3SysMem = $null
$vm4SysMem = $null

$sensorProcessNames = @("minionhost", "ActiveConsole", "CrsSvc", "PylumLoader", "AmSvc", "WscIfSvc", "ExecutionPreventionSvc", "ActiveCLIAgent", "CrAmTray", "Nnx", "CrEX3", "CybereasonAV", "CrDrvCtrl", "CrScanTool")
$allTraces = @(Get-ChildItem $TraceDir -Filter "*.etl" -ErrorAction SilentlyContinue)
$traceScenarios = $allTraces | ForEach-Object { $_.BaseName -replace '_TEST-PERF-.*$','' -replace '_DESKTOP-.*$','' } | Where-Object { $_ } | Select-Object -Unique

# Run ETL on all traces (no symbols, fast) to find scenario with sensor in top processes
$etlProject = Join-Path $scriptDir "etl-analyzer\EtlAnalyzer.csproj"
$scenarioScores = @{}
if (-not $Scenario -and (Test-Path $TraceDir) -and $allTraces.Count -gt 0 -and (Test-Path $etlProject)) {
    Write-Host "Scanning traces for scenario with sensor processes..." -ForegroundColor Cyan
    $etlQuick = Join-Path $env:TEMP "exec-etl-quick-$(Get-Date -Format 'yyyyMMddHHmmss').json"
    $ErrorActionPreferencePrev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $etlOut = & dotnet run --project $etlProject -- $TraceDir --limit 15 2>&1 | Out-String
    $ErrorActionPreference = $ErrorActionPreferencePrev
    $jsonMatch = [regex]::Match($etlOut, '\{\s*"traces"\s*:[\s\S]*\}')
    if ($jsonMatch.Success) {
        $quickData = $jsonMatch.Value | ConvertFrom-Json
        foreach ($t in $quickData.traces) {
            if ($t.error) { continue }
            $topProc = $t.topProcesses | Select-Object -First 1
            $top3 = $t.topProcesses | Select-Object -First 3
            $sensorInTop = $top3 | Where-Object { $sensorProcessNames -contains $_.process }
            $score = 0
            if ($topProc -and $sensorProcessNames -contains $topProc.process) { $score = 100 }
            elseif ($sensorInTop) { $score = 50 }
            $peakCpu = 0
            if ($influxData -and $influxData.sensorCpu) {
                $ic = $influxData.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-3" -and $_.scenario -eq $t.scenario } | Select-Object -First 1
                if ($ic) { $peakCpu = $ic.peakCpu }
            }
            $existing = $scenarioScores[$t.scenario]
            if (-not $existing -or $score -gt $existing.score -or ($score -eq $existing.score -and $peakCpu -gt $existing.peakCpu)) {
                $scenarioScores[$t.scenario] = @{ score = $score; peakCpu = $peakCpu; trace = $t }
            }
        }
    }
}

# Pick: 1) forced -Scenario, 2) highest CPU among scenarios with sensor in top, 3) default
if ($Scenario) {
    $scenario = $Scenario
    Write-Host "Using forced scenario: $scenario" -ForegroundColor Cyan
} elseif ($scenarioScores.Count -gt 0) {
    $withSensor = $scenarioScores.GetEnumerator() | Where-Object { $_.Value.score -gt 0 } | Sort-Object { $_.Value.peakCpu } -Descending
    if ($withSensor) {
        $scenario = ($withSensor | Select-Object -First 1).Key
        Write-Host "Using highest CPU scenario with sensor in top: $scenario ($([math]::Round(($withSensor | Select-Object -First 1).Value.peakCpu, 0))% peak)" -ForegroundColor Cyan
    } else {
        $candidates = $scenarioScores.GetEnumerator() | Sort-Object { $_.Value.peakCpu } -Descending
        $scenario = ($candidates | Select-Object -First 1).Key
    }
} elseif ($influxData -and $influxData.sensorCpu) {
    $worst = $influxData.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-3" } | Sort-Object { $_.peakCpu } -Descending | Select-Object -First 1
    if ($worst) { $scenario = $worst.scenario; Write-Host "Using highest CPU scenario: $scenario ($([math]::Round($worst.peakCpu, 0))% peak)" -ForegroundColor Cyan }
}
if (-not $scenario -and $traceScenarios.Count -gt 0) { $scenario = $traceScenarios[0] }
if (-not $scenario) { $scenario = "combined_high_density" }

# Ensure TraceDir has traces for this scenario; prefer playground (symbols load better)
if ($scenario) {
    $checkDirs = @("C:\Users\OmerMunchik\playground\traces\2026-02-23", (Join-Path $toolsDir "fresh-traces\2026-02-23"))
    foreach ($d in $checkDirs) {
        if (Test-Path $d) {
            $hasScenario = Get-ChildItem $d -Filter "*.etl" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$scenario*" }
            if ($hasScenario) { $TraceDir = $d; break }
        }
    }
}

if ($influxData -and $influxData.sensorCpu) {
    $vm3SensorCpu = $influxData.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-3" -and $_.scenario -eq $scenario } | Select-Object -First 1
    $vm4SensorCpu = $influxData.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-4" -and $_.scenario -eq $scenario } | Select-Object -First 1
    $vm3SysCpu = $influxData.systemCpu | Where-Object { $_.host -eq "TEST-PERF-3" -and $_.scenario -eq $scenario } | Select-Object -First 1
    $vm4SysCpu = $influxData.systemCpu | Where-Object { $_.host -eq "TEST-PERF-4" -and $_.scenario -eq $scenario } | Select-Object -First 1
    $vm3SysMem = $influxData.systemMem | Where-Object { $_.host -eq "TEST-PERF-3" -and $_.scenario -eq $scenario } | Select-Object -First 1
    $vm4SysMem = $influxData.systemMem | Where-Object { $_.host -eq "TEST-PERF-4" -and $_.scenario -eq $scenario } | Select-Object -First 1
}

# --- Run ETL analyzer for this scenario only (with symbols) ---
$etlData = $null
$etlProject = Join-Path $scriptDir "etl-analyzer\EtlAnalyzer.csproj"
$matchingTraces = @(Get-ChildItem $TraceDir -Filter "*.etl" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$scenario*" })
$hasTraces = (Test-Path $TraceDir) -and ($matchingTraces.Count -gt 0)
if ($hasTraces -and (Test-Path $etlProject)) {
    Write-Host "Analyzing ETL trace for $scenario (with symbols, ~2-5 min)..." -ForegroundColor Cyan
    $etlJson = Join-Path $env:TEMP "exec-etl-$(Get-Date -Format 'yyyyMMddHHmmss').json"
    $symPath = "srv*$env:LOCALAPPDATA\Symbols*\\172.25.1.155\symbols-releases;srv*$env:LOCALAPPDATA\Symbols*https://msdl.microsoft.com/download/symbols"
    $env:_NT_SYMBOL_PATH = $symPath
    try {
        $etlArgs = @("run", "--project", $etlProject, "--", $TraceDir, "--symbols", "--symbol-path", $symPath, "--scenario", $scenario, "--limit", "1")
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
    Write-Host "Skipping ETL (no traces for $scenario in $TraceDir)" -ForegroundColor Yellow
}

# --- Build report ---
$sb = [System.Text.StringBuilder]::new()

[void]$sb.AppendLine("# ActiveProbe Sensor Performance - Executive Summary")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("**Test:** $scenario | **Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# One-line takeaway
$peakPct = if ($vm3SensorCpu) { [math]::Round($vm3SensorCpu.peakCpu, 0) } else { "N/A" }
[void]$sb.AppendLine("## Bottom Line")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("During **$scenario**, the sensor used **$peakPct% of one CPU core** at peak (target: under 15%).")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("*Explanation: 100% = one full core. $peakPct% means the sensor used that much of a core at its worst moment (over 100% = more than one core).*")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# VM3 vs VM4 comparison
[void]$sb.AppendLine("## With vs Without Sensor")
[void]$sb.AppendLine("")
[void]$sb.AppendLine('| Metric | VM3 (with sensor) | VM4 (no sensor) | Sensor overhead |')
[void]$sb.AppendLine('|--------|-------------------|-----------------|-----------------|')

$fmtCpu = { param($x) if ($x -and $x.avgCpu -ge 0) { [math]::Round($x.avgCpu, 1).ToString() + "%" } else { "N/A" } }
$fmtCpuPeak = { param($x) $v = if ($null -ne $x.peakCpu) { $x.peakCpu } else { $x.avgCpu }; if ($x -and $v -ge 0) { [math]::Round($v, 1).ToString() + "%" } else { "N/A" } }
$fmtMem = { param($x, $f) if (-not $x) { return "N/A" }; $v = if ($f -eq "avg") { $x.avgAvailableMB } else { $x.peakAvailableMB }; if (-not $v -and $x.availableMB) { $v = $x.availableMB }; if ($v -gt 0) { [math]::Round($v, 0).ToString() + " MB free" } else { "N/A" } }
$v3CpuAvg = & $fmtCpu $vm3SysCpu; $v4CpuAvg = & $fmtCpu $vm4SysCpu
$v3CpuPeak = & $fmtCpuPeak $vm3SysCpu; $v4CpuPeak = & $fmtCpuPeak $vm4SysCpu
$v3MemAvg = & $fmtMem $vm3SysMem "avg"; $v4MemAvg = & $fmtMem $vm4SysMem "avg"
$v3MemPeak = & $fmtMem $vm3SysMem "peak"; $v4MemPeak = & $fmtMem $vm4SysMem "peak"
$overheadCpuAvg = if ($vm3SysCpu -and $vm4SysCpu -and $vm3SysCpu.avgCpu -gt 0 -and $vm4SysCpu.avgCpu -ge 0) { "+" + [math]::Round($vm3SysCpu.avgCpu - $vm4SysCpu.avgCpu, 1).ToString() + "%" } else { "N/A" }
$overheadCpuPeak = if ($vm3SysCpu -and $vm4SysCpu -and $vm3SysCpu.peakCpu -gt 0 -and $vm4SysCpu.peakCpu -ge 0) { "+" + [math]::Round($vm3SysCpu.peakCpu - $vm4SysCpu.peakCpu, 1).ToString() + "%" } else { "N/A" }
$m3Avg = if ($vm3SysMem) { $vm3SysMem.avgAvailableMB }; if (-not $m3Avg -and $vm3SysMem) { $m3Avg = $vm3SysMem.availableMB }; $m4Avg = if ($vm4SysMem) { $vm4SysMem.avgAvailableMB }; if (-not $m4Avg -and $vm4SysMem) { $m4Avg = $vm4SysMem.availableMB }
$m3Peak = if ($vm3SysMem) { $vm3SysMem.peakAvailableMB }; if (-not $m3Peak -and $vm3SysMem) { $m3Peak = $vm3SysMem.availableMB }; $m4Peak = if ($vm4SysMem) { $vm4SysMem.peakAvailableMB }; if (-not $m4Peak -and $vm4SysMem) { $m4Peak = $vm4SysMem.availableMB }
$overheadMemAvg = if ($vm3SysMem -and $vm4SysMem -and $m3Avg -gt 0 -and $m4Avg -gt 0) { "-" + [math]::Round($m4Avg - $m3Avg, 0).ToString() + " MB" } else { "N/A" }
$overheadMemPeak = if ($vm3SysMem -and $vm4SysMem -and $m3Peak -gt 0 -and $m4Peak -gt 0) { "-" + [math]::Round($m4Peak - $m3Peak, 0).ToString() + " MB" } else { "N/A" }
[void]$sb.AppendLine("| System CPU (avg) | $v3CpuAvg | $v4CpuAvg | $overheadCpuAvg |")
[void]$sb.AppendLine("| System CPU (peak) | $v3CpuPeak | $v4CpuPeak | $overheadCpuPeak |")
[void]$sb.AppendLine("| System memory available (peak) | $v3MemPeak | $v4MemPeak | $overheadMemPeak |")
[void]$sb.AppendLine("| System memory available (avg) | $v3MemAvg | $v4MemAvg | $overheadMemAvg |")
if ($v3CpuAvg -eq "N/A" -or $v3MemAvg -eq "N/A") {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("*If System CPU/memory show N/A: run `.\tools\influx-dump-raw.ps1` on MON VM to diagnose InfluxDB parsing.*")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("*Sensor overhead = how much worse the system is with the sensor. Negative memory = less free RAM with sensor.*")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("")

# Top processes and bottlenecks - prefer trace from symbol run (etlData), fallback to quick scan
$trace = $null
if ($etlData -and $etlData.traces -and $etlData.traces.Count -gt 0) {
    $trace = $etlData.traces | Where-Object { $_.scenario -eq $scenario -and -not $_.error } | Select-Object -First 1
    if (-not $trace) { $trace = $etlData.traces | Where-Object { -not $_.error } | Select-Object -First 1 }
}
if (-not $trace -and $scenarioScores[$scenario] -and $scenarioScores[$scenario].trace) {
    $trace = $scenarioScores[$scenario].trace
}

$processRoles = @{
    minionhost = "ActiveProbe sensor core; handles telemetry, policy, and agent logic"
    ActiveConsole = "Sensor UI component"
    lsass = "Local Security Authority; Windows authentication and security (user account changes trigger it)"
    svchost = "Service host; runs Windows services (e.g. RPC, WMI)"
    System = "Windows kernel; CPU time attributed to kernel/drivers"
    net1 = "Network helper; used during user/group management operations"
    powershell = "Test harness or automation"
    OpenConsole = "Windows Terminal / console host"
    WindowsTerminal = "Terminal emulator"
    cmd = "Command prompt"
    TiWorker = "Windows Update / Trusted Installer"
    net = "Network command-line tool"
    WmiPrvSE = "WMI provider host"
}
if ($trace -and ($trace.topProcesses -or $trace.TopProcesses)) {
    $procList = @($trace.topProcesses)
    if (-not $procList -or $procList.Count -eq 0) { $procList = @($trace.TopProcesses) }
    $sensorProcs = @($procList | Where-Object {
        $pn = $_.process
        if (-not $pn) { $pn = $_.Process }
        $pn -and ($sensorProcessNames -contains $pn)
    } | Select-Object -First 5)
    if ($sensorProcs.Count -eq 0 -and $scenarioScores[$scenario].trace) {
        $altTrace = $scenarioScores[$scenario].trace
        $procList = @($altTrace.topProcesses) + @($altTrace.TopProcesses) | Where-Object { $_ }
        $sensorProcs = @($procList | Where-Object { $_.process -and ($sensorProcessNames -contains $_.process) } | Select-Object -First 5)
    }
    [void]$sb.AppendLine("## Top 5 Sensor Processes (Who Used CPU)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Process | Role | CPU time (ms) | Percent |")
    [void]$sb.AppendLine("|---------|------|---------------|---------|")
    if ($sensorProcs.Count -gt 0) {
        foreach ($p in $sensorProcs) {
            $role = if ($processRoles[$p.process]) { $processRoles[$p.process] } else { "Sensor component" }
            [void]$sb.AppendLine("| $($p.process) | $role | $($p.weightMs) | $($p.percent)% |")
        }
    } else {
        [void]$sb.AppendLine("| *(no sensor processes in top during this trace)* | - | - | - |")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("*Percent = share of total CPU samples collected during the trace (all cores). Sensor processes only.*")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine("")
}

# Bottleneck functions (from ETL; only real function names, prefer sensor modules)
if ($trace -and $trace.topFunctions) {
    $sensorModules = @("minionhost", "ActiveConsole", "CrsSvc", "PylumLoader", "AmSvc", "WscIfSvc", "ExecutionPreventionSvc", "ActiveCLIAgent", "CrAmTray", "Nnx", "CrEX3", "CybereasonAV", "CrDrvCtrl", "CrScanTool")
    $isAddress = { param($f) $fn = $f.function; $fn -and $fn -match '^0x[0-9A-Fa-f]+$' }
    $sensorFuncsWithNames = $trace.topFunctions | Where-Object { $sensorModules -contains $_.module -and -not (& $isAddress $_) } | Select-Object -First 8
    if ($sensorFuncsWithNames.Count -eq 0) {
        $sensorFuncsWithNames = $trace.topFunctions | Where-Object { -not (& $isAddress $_) } | Select-Object -First 8
    }

    [void]$sb.AppendLine("## Main Bottlenecks (Sensor Code Hotspots)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Module | Function | Percent |")
    [void]$sb.AppendLine("|--------|----------|---------|")
    if ($sensorFuncsWithNames.Count -gt 0) {
        foreach ($f in $sensorFuncsWithNames) {
            $mod = if ($f.module) { $f.module } else { "-" }
            $fn = if ($f.function) { $f.function } else { ($f.PSObject.Properties['function'].Value -replace '^[^!]+!', '') }
            if (-not $fn -and $f.PSObject.Properties['function']) { $fn = $f.function }
            [void]$sb.AppendLine("| $mod | $fn | $($f.percent)% |")
        }
    } else {
        [void]$sb.AppendLine("| *(Symbols unavailable - connect to \\\\172.25.1.155\\symbols-releases for real names)* | - | - |")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("*Percent = share of total CPU samples during the trace. These functions inside the sensor consumed the most CPU; optimize them first to reduce sensor load.*")
    [void]$sb.AppendLine("")
}

$report = $sb.ToString()
if (Test-Path $OutputPath) {
    $backupPath = Join-Path (Split-Path $OutputPath) "executive-summary-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
    Copy-Item $OutputPath $backupPath -Force
    Write-Host "Backed up previous report to: $backupPath" -ForegroundColor Cyan
}
$report | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Executive summary written to: $OutputPath" -ForegroundColor Green
