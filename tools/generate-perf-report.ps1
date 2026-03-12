<#
.SYNOPSIS
    Orchestrates InfluxDB and ETL analysis, then generates a consolidated performance bottleneck report.

.DESCRIPTION
    Runs influx-analyze.ps1 and EtlAnalyzer, merges findings, and produces a Markdown report.

.PARAMETER TraceDir
    Path to directory containing .etl trace files (default: C:\PerfTest\traces).

.PARAMETER Token
    InfluxDB API token. If not provided, uses $env:INFLUXDB_TOKEN.

.PARAMETER InfluxUrl
    InfluxDB base URL (default: http://172.46.16.24:8086).

.PARAMETER TimeRange
    Flux time range for InfluxDB queries (default: -7d).

.PARAMETER OutputPath
    Path for the generated report. Default: perf-bottleneck-report-YYYYMMDD.html in tools directory.

.PARAMETER UseSymbols
    If set, ETL analyzer loads symbols for function names (slower, requires network).

.PARAMETER SkipInfluxDB
    Skip InfluxDB analysis (use when MON VM is unreachable). Report will include ETL data only.

.PARAMETER TraceLimit
    Process only the first N trace files (for quick test). Default: 0 = all traces.

.PARAMETER InfluxJsonPath
    Path to pre-fetched InfluxDB JSON (from running influx-analyze.ps1 on MON VM).
    Use when your workstation cannot reach InfluxDB directly.

.PARAMETER NumCores
    Number of CPU cores on the VMs (for normalizing per-process CPU%). Default: 2.

.PARAMETER EtlOutputPath
    Path for the separate ETL report. Default: perf-report-etl.html in the same directory as OutputPath.

.EXAMPLE
    $env:INFLUXDB_TOKEN = "your-token"
    .\generate-perf-report.ps1 -TraceDir "C:\PerfTest\traces"

.EXAMPLE
    .\generate-perf-report.ps1 -TraceDir "C:\traces\2026-02-23" -InfluxJsonPath "C:\temp\influx-data.json"

.EXAMPLE
    .\generate-perf-report.ps1 -SkipInfluxDB -TraceLimit 2
#>

[CmdletBinding()]
param(
    [string]$TraceDir = "C:\PerfTest\traces",
    [string]$Token = $env:INFLUXDB_TOKEN,
    [string]$InfluxUrl = "http://172.46.16.24:8086",
    [string]$TimeRange = "-7d",
    [string]$OutputPath,
    [switch]$UseSymbols,
    [switch]$SkipInfluxDB,
    [switch]$SkipEtl,
    [int]$TraceLimit = 0,
    [string]$InfluxJsonPath,
    [int]$NumCores = 2,
    [string]$EtlOutputPath,
    [string]$EtlJsonPath,
    [switch]$GenerateConfluence,
    [switch]$LightMode,
    [string]$ScenarioResultsDir
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir = Split-Path -Parent $scriptDir

# ── Color helpers ──

function Get-CpuColor($val, $warnThreshold, $critThreshold) {
    if ($val -ge $critThreshold) { return "#e74c3c" }
    if ($val -ge $warnThreshold) { return "#f39c12" }
    return "#27ae60"
}
function Get-MemColor($val) {
    if ($val -ge 500) { return "#e74c3c" }
    if ($val -ge 200) { return "#f39c12" }
    return "#27ae60"
}
function Get-ProcMemColor($val) {
    if ($val -ge 200) { return "#c0392b" }
    if ($val -ge 50) { return "#d68910" }
    return "#1e8449"
}
function Get-SysMemColor($usedMB) {
    if ($usedMB -ge 3500) { return "#e74c3c" }
    if ($usedMB -ge 2500) { return "#f39c12" }
    return "#27ae60"
}

# ── Shared CSS ──

$script:SharedCss = @"
body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #fff; color: #333; margin: 20px; max-width: 1400px; }
h1 { color: #2980b9; border-bottom: 2px solid #2980b9; padding-bottom: 8px; }
h2 { color: #2980b9; border-left: 4px solid #2980b9; padding-left: 12px; margin-top: 28px; }
h3 { color: #34495e; margin-top: 20px; }
table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 13px; }
th, td { border: 1px solid #bdc3c7; padding: 6px 10px; text-align: left; }
th { background: #ecf0f1; font-weight: 600; }
tr:nth-child(even) { background: #f8f9fa; }
tr:nth-child(odd) { background: #fff; }
.numeric { font-family: 'Consolas', 'Monaco', monospace; }
.summary-box { padding: 16px; margin: 16px 0; border-radius: 4px; border-left: 4px solid; }
.summary-ok { background: #e8f8f5; border-color: #27ae60; }
.summary-warn { background: #fef9e7; border-color: #f39c12; }
.summary-crit { background: #fdedec; border-color: #e74c3c; }
.callout { background: #ebf5fb; border-left: 4px solid #2980b9; padding: 12px 16px; margin: 16px 0; }
.highlight-row { background: #fef9e7 !important; border: 2px solid #f39c12; }
.worst-s2-row { background: #fdedec !important; border: 2px solid #e74c3c; font-weight: bold; }
.vm-separator { border-left: 3px solid #2980b9 !important; }
.bottom-line { background: #fdf2e9; border-left: 4px solid #e67e22; padding: 16px; margin: 16px 0; }
.finding { margin-bottom: 10px; }
.finding strong { color: #2c3e50; }
.na-cell { background: #ecf0f1 !important; color: #7f8c8d !important; font-style: italic; cursor: help; }
.total-row td { border-top: 2px solid #2c3e50; font-weight: bold; background: #ebedef !important; }
.group-header th { text-align: center; font-size: 14px; font-weight: 700; }
.sub-header th { text-align: center; font-size: 11px; font-weight: 600; background: #dde4e6; }
.cpu-cell { font-family: 'Consolas', monospace; text-align: right; }
.mem-cell { font-family: 'Consolas', monospace; text-align: right; }
@media print { body { margin: 10px; } .no-print { display: none; } }
"@

# ── Scenario descriptions (ordered: file-heavy scenarios last) ──

if ($LightMode) {
    $script:ScenarioDescriptions = [ordered]@{
        "idle_baseline"          = "Idle baseline - no workload running (5 min)"
        "registry_storm"         = "Rapid registry key set/delete operations (200 keys x 10 iterations)"
        "network_burst"          = "HTTP request burst to external endpoints (50 requests x 10 iterations)"
        "process_storm"          = "Rapid process spawn and terminate cycles (30 processes x 10 bursts)"
        "rpc_generation"         = "WMI/RPC query loop simulating management traffic (100 queries x 10 iterations)"
        "service_cycle"          = "Windows service create/start/stop/delete cycle (20 cycles)"
        "user_account_modify"    = "User account create/modify/delete cycle (20 cycles)"
        "browser_streaming"      = "Browser streaming session simulation (3 minutes)"
        "driver_load"            = "Driver load/unload via Defender restart (3 cycles)"
        "file_stress_loop"       = "Continuous file create/rename/delete loop (500 files x 5 iterations)"
        "zip_extraction"         = "ZIP extraction workload - archive with 2,000 files (3 iterations)"
        "file_storm"             = "Mass file create/modify/delete in bursts (2,000 files x 5 bursts)"
        "combined_high_density"  = "All workload generators running in parallel (5 minutes)"
    }
} else {
    $script:ScenarioDescriptions = [ordered]@{
        "idle_baseline"          = "Idle baseline - no workload running, measures resting CPU and memory consumption"
        "registry_storm"         = "Rapid registry key set/delete operations (2000 keys x 100 iterations)"
        "network_burst"          = "HTTP request burst to external endpoints (300 requests x 50 iterations)"
        "process_storm"          = "Rapid process spawn and terminate cycles (100 processes x 30 bursts)"
        "rpc_generation"         = "WMI/RPC query loop simulating management traffic (500 queries x 25 iterations)"
        "service_cycle"          = "Windows service create/start/stop/delete cycle (200 cycles)"
        "user_account_modify"    = "User account create/modify/delete cycle (200 cycles)"
        "browser_streaming"      = "Browser streaming session simulation (15 minutes)"
        "driver_load"            = "Driver load/unload via Defender restart (10 cycles)"
        "file_stress_loop"       = "Continuous file create/rename/delete loop (5000 files x 100 iterations)"
        "zip_extraction"         = "ZIP extraction workload - archive with 10,000 files (10 iterations)"
        "file_storm"             = "Mass file create/modify/delete in bursts (10,000 files x 30 bursts)"
        "combined_high_density"  = "All workload generators running in parallel (15 minutes)"
    }
}

# ── Build the main report ──

function Build-Report {
    param($InfluxData, [int]$NumCores = 2)

    # Remap legacy hostnames only when the new name has no data
    $hostAliases = @{ "TEST-PERF-3" = "TEST-PERF-S1" }
    if ($InfluxData) {
        foreach ($prop in @('sensorCpu','sensorMemory','systemCpu','systemMem','diskIo','networkIo','sensorDbSize','sensorLiveness','sensorLivenessUptime','driverInstances','systemProcessCpu','systemProcessMemory','kpiFailures','kernelPoolMB')) {
            if ($InfluxData.$prop) {
                foreach ($oldName in $hostAliases.Keys) {
                    $newName = $hostAliases[$oldName]
                    $hasNewData = @($InfluxData.$prop | Where-Object { $_.host -eq $newName }).Count -gt 0
                    if (-not $hasNewData) {
                        foreach ($item in $InfluxData.$prop) {
                            if ($item.host -eq $oldName) { $item.host = $newName }
                        }
                    }
                }
            }
        }

    # Filter to small VMs only
        $hostFilter = { $_.host -like "TEST-PERF-S*" }
        foreach ($prop in @('sensorCpu','sensorMemory','systemCpu','systemMem','diskIo','networkIo','sensorDbSize','sensorLiveness','sensorLivenessUptime','driverInstances','systemProcessCpu','systemProcessMemory','kpiFailures','kernelPoolMB')) {
            if ($InfluxData.$prop) { $InfluxData.$prop = @($InfluxData.$prop | Where-Object $hostFilter) }
        }
        if ($InfluxData.sensorDeltas) { $InfluxData.sensorDeltas = @() }
        if ($InfluxData.versionComparison) {
            $InfluxData.versionComparison = @($InfluxData.versionComparison | Where-Object {
                $allSmall = $true; foreach ($h in $_.hosts) { if ($h -notlike "TEST-PERF-S*") { $allSmall = $false } }; $allSmall
            })
        }
        if ($InfluxData.backendComparison) {
            $InfluxData.backendComparison = @($InfluxData.backendComparison | Where-Object {
                $allSmall = $true; foreach ($h in $_.hosts) { if ($h -notlike "TEST-PERF-S*") { $allSmall = $false } }; $allSmall
            })
        }
    }

    # ── Normalize per-process CPU by num_cores ──
    if ($InfluxData -and $NumCores -gt 1) {
        foreach ($c in $InfluxData.sensorCpu) {
            $c.avgCpu = [double]$c.avgCpu / $NumCores
            $c.peakCpu = [double]$c.peakCpu / $NumCores
        }
        foreach ($c in $InfluxData.systemProcessCpu) {
            $c.avgCpu = [double]$c.avgCpu / $NumCores
            $c.peakCpu = [double]$c.peakCpu / $NumCores
        }
        foreach ($v in $InfluxData.versionComparison) {
            $v.avgCpu = [double]$v.avgCpu / $NumCores
        }
        foreach ($b in $InfluxData.backendComparison) {
            $b.avgCpu = [double]$b.avgCpu / $NumCores
        }
    }

    $roleMap = @{
        "TEST-PERF-S1" = "No Sensor (Baseline)"
        "TEST-PERF-S2" = "V26.1 + Phoenix"
        "TEST-PERF-S3" = "V26.1 + Legacy"
        "TEST-PERF-S4" = "V24.1 + Legacy"
    }
    function Get-Role($hostName) { if ($roleMap[$hostName]) { $roleMap[$hostName] } else { $hostName } }

    $script:_reverseRoleMap = @{}
    foreach ($k in $roleMap.Keys) { $script:_reverseRoleMap[$roleMap[$k]] = $k }
    function Get-HostFromRole($role) { if ($script:_reverseRoleMap[$role]) { return $script:_reverseRoleMap[$role] } else { return $role } }

    $allRoles = @("No Sensor (Baseline)", "V26.1 + Phoenix", "V26.1 + Legacy", "V24.1 + Legacy")
    $allHosts = @("TEST-PERF-S1", "TEST-PERF-S2", "TEST-PERF-S3", "TEST-PERF-S4")
    $sensorRoles = @("V26.1 + Phoenix", "V26.1 + Legacy", "V24.1 + Legacy")
    $sensorHosts = @("TEST-PERF-S2", "TEST-PERF-S3", "TEST-PERF-S4")
    $s1 = "TEST-PERF-S1"; $s2 = "TEST-PERF-S2"; $s3 = "TEST-PERF-S3"; $s4 = "TEST-PERF-S4"

    $allScenarios = @($script:ScenarioDescriptions.Keys)

    $sb = [System.Text.StringBuilder]::new()

    # ── HTML header ──
    $genTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [void]$sb.AppendLine(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cybereason Sensor Performance Report</title>
<style>
$($script:SharedCss)
</style>
</head>
<body>
<h1>Cybereason Sensor Performance Report</h1>
<p><strong>Generated:</strong> $genTime</p>
"@)

    # Test start/end/duration
    $testStartStr = ""; $testEndStr = ""; $testDurStr = ""
    if ($InfluxData) {
        $startDt = $null; $endDt = $null
        if ($InfluxData.testStartTime -and $InfluxData.testStartTime -ne "") {
            try { $startDt = [DateTime]::Parse($InfluxData.testStartTime) } catch {}
        }
        if (-not $startDt -and $InfluxData.timeRange -and $InfluxData.timeRange -ne "") {
            try { $startDt = [DateTime]::Parse($InfluxData.timeRange) } catch {}
        }
        if ($InfluxData.testEndTime -and $InfluxData.testEndTime -ne "") {
            try { $endDt = [DateTime]::Parse($InfluxData.testEndTime) } catch {}
        }
        if (-not $endDt -and $InfluxData.timestamp -and $InfluxData.timestamp -ne "") {
            try { $endDt = [DateTime]::Parse($InfluxData.timestamp) } catch {}
        }
        if ($startDt) {
            $testStartStr = $startDt.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
            if ($endDt) {
                $testEndStr = $endDt.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                $dur = $endDt - $startDt
                $testDurStr = "{0}h {1}m" -f [int][math]::Floor($dur.TotalHours), $dur.Minutes
            }
        }
    }
    if ($testStartStr) {
        $timeLine = "<p><strong>Test Start:</strong> $testStartStr"
        if ($testEndStr) { $timeLine += " &nbsp;|&nbsp; <strong>Test End:</strong> $testEndStr" }
        if ($testDurStr) { $timeLine += " &nbsp;|&nbsp; <strong>Duration:</strong> $testDurStr" }
        $timeLine += "</p>"
        [void]$sb.AppendLine($timeLine)
    }

    [void]$sb.AppendLine("<p><strong>Scope:</strong> Small VMs &mdash; S1: No Sensor Baseline, S2: V26.1+Phoenix, S3: V26.1+Legacy, S4: V24.1+Legacy</p>")

    # ════════════════════════════════════════════════
    # 1. TEST ENVIRONMENT
    # ════════════════════════════════════════════════
    [void]$sb.AppendLine("<h2>Test Environment</h2>")
    [void]$sb.AppendLine("<table><tr><th>Hostname</th><th>Role</th><th>IP Address</th><th>Machine Type</th></tr>")
    [void]$sb.AppendLine("<tr><td>TEST-PERF-S1</td><td>No Sensor (Baseline)</td><td>172.46.17.140</td><td>Small (2 vCPU, 4 GB RAM)</td></tr>")
    [void]$sb.AppendLine("<tr><td>TEST-PERF-S2</td><td>V26.1 + Phoenix</td><td>172.46.16.179</td><td>Small (2 vCPU, 4 GB RAM)</td></tr>")
    [void]$sb.AppendLine("<tr><td>TEST-PERF-S3</td><td>V26.1 + Legacy</td><td>172.46.17.21</td><td>Small (2 vCPU, 4 GB RAM)</td></tr>")
    [void]$sb.AppendLine("<tr><td>TEST-PERF-S4</td><td>V24.1 + Legacy</td><td>172.46.17.40</td><td>Small (2 vCPU, 4 GB RAM)</td></tr>")
    [void]$sb.AppendLine("</table>")

    # ════════════════════════════════════════════════
    # 2. TEST SCENARIOS
    # ════════════════════════════════════════════════
    [void]$sb.AppendLine("<h2>Test Scenarios</h2>")
    [void]$sb.AppendLine("<table><tr><th>#</th><th>Scenario Name</th><th>Description</th></tr>")
    $idx = 1
    foreach ($sc in $allScenarios) {
        [void]$sb.AppendLine("<tr><td>$idx</td><td><code>$sc</code></td><td>$($script:ScenarioDescriptions[$sc])</td></tr>")
        $idx++
    }
    [void]$sb.AppendLine("</table>")

    [void]$sb.AppendLine(@"
<div class="summary-box summary-warn">
<strong>About N/A values in this report:</strong> Cells marked <span class="na-cell" style="padding: 2px 6px;">N/A</span> indicate that the scenario did not complete on that host, so no data was collected. Some sensor hosts may not complete file-heavy scenarios (<code>file_stress_loop</code>, <code>file_storm</code>, <code>zip_extraction</code>, <code>combined_high_density</code>) because the <strong>Nnx component</strong> (a file-monitoring process present in all sensor versions) can cause extreme CPU load during file-heavy tests, leaving insufficient CPU for the test harness to complete within the allotted time.
</div>
"@)

    # ════════════════════════════════════════════════
    # 3. EXECUTIVE SUMMARY
    # ════════════════════════════════════════════════
    [void]$sb.AppendLine("<h2>Executive Summary</h2>")
    if (-not $InfluxData) {
        [void]$sb.AppendLine('<div class="summary-box summary-warn"><strong>No InfluxDB data available.</strong> Cannot assess performance.</div>')
    } else {
        $sensorVm = if ($InfluxData.sensorCpu) { $InfluxData.sensorCpu } else { @() }
        $s2Cpu = $sensorVm | Where-Object { $_.host -eq $s2 }
        $maxS2Avg = if ($s2Cpu.Count -gt 0) { $max = 0; $s2Cpu | ForEach-Object { if ([double]$_.avgCpu -gt $max) { $max = [double]$_.avgCpu } }; $max } else { 0 }
        $maxS2Peak = if ($s2Cpu.Count -gt 0) { $max = 0; $s2Cpu | ForEach-Object { if ([double]$_.peakCpu -gt $max) { $max = [double]$_.peakCpu } }; $max } else { 0 }
        $worstS2Scenario = if ($s2Cpu.Count -gt 0) { ($s2Cpu | Sort-Object -Property { [double]$_.peakCpu } -Descending | Select-Object -First 1).scenario } else { "N/A" }

        if ($maxS2Peak -lt 10) {
            [void]$sb.AppendLine('<div class="summary-box summary-ok"><strong>V26.1 + Phoenix:</strong> CPU usage is within acceptable ranges across all scenarios.</div>')
        } elseif ($maxS2Peak -lt 30) {
            [void]$sb.AppendLine("<div class=`"summary-box summary-warn`"><strong>V26.1 + Phoenix:</strong> Peak sensor CPU reached <span class=`"numeric`">$([math]::Round($maxS2Peak, 1))%</span> during <code>$worstS2Scenario</code>.</div>")
        } else {
            [void]$sb.AppendLine("<div class=`"summary-box summary-crit`"><strong>V26.1 + Phoenix:</strong> High sensor CPU of <span class=`"numeric`">$([math]::Round($maxS2Peak, 1))%</span> during <code>$worstS2Scenario</code>.</div>")
        }
    }

    [void]$sb.AppendLine(@"
<div class="callout">
<strong>CPU% Definition:</strong> All per-process CPU values are <em>Windows '% Processor Time'</em> divided by the number of CPU cores ($NumCores). This normalizes to a 0&ndash;100% scale representing percentage of total system capacity. Sensor CPU is the sum across all sensor processes (minionhost, ActiveConsole, PylumLoader, etc.).
</div>
"@)

    # ════════════════════════════════════════════════
    # HELPER: compute row classes for a scenario table
    # ════════════════════════════════════════════════
    # Returns hashtable: scenario -> "highlight-row" | "worst-s2-row" | ""
    # $getS2Value: scriptblock taking (scenario, data) returning numeric value for S2
    # $getVariance: scriptblock taking (scenario, data) returning variance value
    function Get-RowClasses {
        param($scenarios, $data, $getS2Val, $getVar)
        $maxVar = 0; $maxVarSc = ""
        $worstS2 = [double]::MinValue; $worstS2Sc = ""
        foreach ($sc in $scenarios) {
            $v = & $getVar $sc $data
            if ($v -gt $maxVar) { $maxVar = $v; $maxVarSc = $sc }
            $s2v = & $getS2Val $sc $data
            if ($s2v -gt $worstS2) { $worstS2 = $s2v; $worstS2Sc = $sc }
        }
        $result = @{}
        foreach ($sc in $scenarios) {
            if ($sc -eq $worstS2Sc -and $sc -eq $maxVarSc) { $result[$sc] = 'worst-s2-row' }
            elseif ($sc -eq $worstS2Sc) { $result[$sc] = 'worst-s2-row' }
            elseif ($sc -eq $maxVarSc) { $result[$sc] = 'highlight-row' }
            else { $result[$sc] = '' }
        }
        return $result
    }

    # ════════════════════════════════════════════════
    # 4. SYSTEM CPU - AVERAGE BY ROLE
    # ════════════════════════════════════════════════
    $sysCpu = if ($InfluxData -and $InfluxData.systemCpu) { $InfluxData.systemCpu } else { @() }
    if ($sysCpu.Count -gt 0) {
        [void]$sb.AppendLine("<h2>System CPU - Average by Role</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> Total system CPU utilization (all processes combined) averaged over each scenario. Sourced from Windows <code>win_cpu _Total</code> counter, already normalized to 0&ndash;100%.<br><br>
<strong>Why baseline (S1) can show higher CPU than sensor hosts:</strong> This metric measures CPU used by <em>all</em> processes, including the test workload scripts themselves (PowerShell, cmd, etc.). The sensor intercepts system calls (file I/O, process creation, registry operations), which throttles the workload, causing it to run longer at lower average CPU intensity. This does <strong>not</strong> mean the sensor reduces CPU usage &mdash; it means the same work is spread over more wall-clock time. The true sensor CPU overhead is isolated in the &ldquo;Sensor CPU&rdquo; and &ldquo;Process CPU Impact&rdquo; sections below.</div>
"@)
        [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
        foreach ($r in $allRoles) { [void]$sb.AppendLine("<th>$r</th>") }
        [void]$sb.AppendLine("</tr>")

        $sysScenarios = @($sysCpu | ForEach-Object { $_.scenario } | Sort-Object -Unique)
        $activeSysScenarios = @($allScenarios | Where-Object { $sysScenarios -contains $_ })

        # Compute row highlights
        $sysCpuAvgClasses = @{}
        $maxVar = 0; $maxVarSc = ""; $worstS2Val = [double]::MinValue; $worstS2Sc = ""
        foreach ($sc in $activeSysScenarios) {
            $vals = @($allHosts | ForEach-Object { $h = $_; $e = $sysCpu | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1; if ($e) { [double]$e.avgCpu } else { 0 } })
            $var = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
            if ($var -gt $maxVar) { $maxVar = $var; $maxVarSc = $sc }
            $s2e = $sysCpu | Where-Object { $_.host -eq $s2 -and $_.scenario -eq $sc } | Select-Object -First 1
            $s2v = if ($s2e) { [double]$s2e.avgCpu } else { 0 }
            if ($s2v -gt $worstS2Val) { $worstS2Val = $s2v; $worstS2Sc = $sc }
        }
        foreach ($sc in $activeSysScenarios) {
            if ($sc -eq $worstS2Sc) { $sysCpuAvgClasses[$sc] = 'worst-s2-row' }
            elseif ($sc -eq $maxVarSc) { $sysCpuAvgClasses[$sc] = 'highlight-row' }
            else { $sysCpuAvgClasses[$sc] = '' }
        }

        foreach ($sc in $allScenarios) {
            if ($sysScenarios -notcontains $sc) { continue }
            $cls = $sysCpuAvgClasses[$sc]
            $rowAttr = if ($cls) { " class=`"$cls`"" } else { '' }
            [void]$sb.AppendLine("<tr$rowAttr><td><code>$sc</code></td>")
            foreach ($r in $allRoles) {
                $h = Get-HostFromRole $r
                $entry = $sysCpu | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1
                if ($entry) {
                    $val = [math]::Round([double]$entry.avgCpu, 1)
                    $color = Get-CpuColor $val 30 70
                    [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $color; color: white;`">$val%</td>")
                } else { [void]$sb.AppendLine("<td class=`"na-cell`" title=`"Scenario did not complete on this host`">N/A</td>") }
            }
            [void]$sb.AppendLine("</tr>")
        }
        [void]$sb.AppendLine("</table>")
        [void]$sb.AppendLine("<p><em>Yellow = largest cross-host variance. Red = worst scenario for V26.1+Phoenix.</em></p>")

    # ════════════════════════════════════════════════
    # 5. SYSTEM CPU - PEAK BY ROLE
    # ════════════════════════════════════════════════
        [void]$sb.AppendLine("<h2>System CPU - Peak by Role</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> The highest instantaneous system CPU utilization (all processes combined) recorded during each scenario. Sourced from Windows <code>win_cpu _Total</code> counter, already normalized to 0&ndash;100%. Peak values reveal worst-case CPU spikes that may not be visible in the averages above.</div>
"@)
        [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
        foreach ($r in $allRoles) { [void]$sb.AppendLine("<th>$r</th>") }
        [void]$sb.AppendLine("</tr>")

        $sysCpuPeakClasses = @{}
        $maxVar = 0; $maxVarSc = ""; $worstS2Val = [double]::MinValue; $worstS2Sc = ""
        foreach ($sc in $activeSysScenarios) {
            $vals = @($allHosts | ForEach-Object { $h = $_; $e = $sysCpu | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1; if ($e) { [double]$e.peakCpu } else { 0 } })
            $var = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
            if ($var -gt $maxVar) { $maxVar = $var; $maxVarSc = $sc }
            $s2e = $sysCpu | Where-Object { $_.host -eq $s2 -and $_.scenario -eq $sc } | Select-Object -First 1
            $s2v = if ($s2e) { [double]$s2e.peakCpu } else { 0 }
            if ($s2v -gt $worstS2Val) { $worstS2Val = $s2v; $worstS2Sc = $sc }
        }
        foreach ($sc in $activeSysScenarios) {
            if ($sc -eq $worstS2Sc) { $sysCpuPeakClasses[$sc] = 'worst-s2-row' }
            elseif ($sc -eq $maxVarSc) { $sysCpuPeakClasses[$sc] = 'highlight-row' }
            else { $sysCpuPeakClasses[$sc] = '' }
        }

        foreach ($sc in $allScenarios) {
            if ($sysScenarios -notcontains $sc) { continue }
            $cls = $sysCpuPeakClasses[$sc]
            $rowAttr = if ($cls) { " class=`"$cls`"" } else { '' }
            [void]$sb.AppendLine("<tr$rowAttr><td><code>$sc</code></td>")
            foreach ($r in $allRoles) {
                $h = Get-HostFromRole $r
                $entry = $sysCpu | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1
                if ($entry) {
                    $val = [math]::Round([double]$entry.peakCpu, 1)
                    $color = Get-CpuColor $val 50 90
                    [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $color; color: white;`">$val%</td>")
                } else { [void]$sb.AppendLine("<td class=`"na-cell`" title=`"Scenario did not complete on this host`">N/A</td>") }
            }
            [void]$sb.AppendLine("</tr>")
        }
        [void]$sb.AppendLine("</table>")
        [void]$sb.AppendLine("<p><em>Yellow = largest cross-host variance. Red = worst scenario for V26.1+Phoenix.</em></p>")
    }

    # ════════════════════════════════════════════════
    # 6. SENSOR CPU - AVERAGE BY ROLE
    # ════════════════════════════════════════════════
    $sensorVm = if ($InfluxData -and $InfluxData.sensorCpu) { $InfluxData.sensorCpu } else { @() }
    if ($sensorVm.Count -gt 0) {
        [void]$sb.AppendLine("<h2>Sensor CPU - Average by Role</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> CPU consumed exclusively by sensor processes (minionhost, ActiveConsole, CrsSvc, PylumLoader, etc.), averaged over each scenario. This is calculated by summing per-process <code>% Processor Time</code> at each sample interval and dividing by the number of cores, giving a 0&ndash;100% normalized value. Unlike the system CPU tables above, this isolates the sensor&rsquo;s own CPU footprint from workload and OS activity.</div>
"@)
        [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
        foreach ($r in $sensorRoles) { [void]$sb.AppendLine("<th>$r</th>") }
        [void]$sb.AppendLine("</tr>")
        $sensorScenarios = @($sensorVm | ForEach-Object { $_.scenario } | Sort-Object -Unique)
        $activeSensorScenarios = @($allScenarios | Where-Object { $sensorScenarios -contains $_ })

        $sensorAvgClasses = @{}
        $maxVar = 0; $maxVarSc = ""; $worstS2Val = [double]::MinValue; $worstS2Sc = ""
        foreach ($sc in $activeSensorScenarios) {
            $vals = @($sensorHosts | ForEach-Object { $h = $_; $e = $sensorVm | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1; if ($e) { [double]$e.avgCpu } else { 0 } })
            $var = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
            if ($var -gt $maxVar) { $maxVar = $var; $maxVarSc = $sc }
            $s2e = $sensorVm | Where-Object { $_.host -eq $s2 -and $_.scenario -eq $sc } | Select-Object -First 1
            $s2v = if ($s2e) { [double]$s2e.avgCpu } else { 0 }
            if ($s2v -gt $worstS2Val) { $worstS2Val = $s2v; $worstS2Sc = $sc }
        }
        foreach ($sc in $activeSensorScenarios) {
            if ($sc -eq $worstS2Sc) { $sensorAvgClasses[$sc] = 'worst-s2-row' }
            elseif ($sc -eq $maxVarSc) { $sensorAvgClasses[$sc] = 'highlight-row' }
            else { $sensorAvgClasses[$sc] = '' }
        }

        foreach ($sc in $allScenarios) {
            if ($sensorScenarios -notcontains $sc) { continue }
            $cls = $sensorAvgClasses[$sc]
            $rowAttr = if ($cls) { " class=`"$cls`"" } else { '' }
            [void]$sb.AppendLine("<tr$rowAttr><td><code>$sc</code></td>")
            foreach ($r in $sensorRoles) {
                $h = Get-HostFromRole $r
                $entry = $sensorVm | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1
                $val = if ($entry) { [double]$entry.avgCpu } else { $null }
                if ($null -ne $val) {
                    $color = Get-CpuColor $val 5 15
                    [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $color; color: white;`">$([math]::Round($val, 1))%</td>")
                } else { [void]$sb.AppendLine("<td class=`"na-cell`" title=`"Scenario did not complete on this host`">N/A</td>") }
            }
            [void]$sb.AppendLine("</tr>")
        }
        [void]$sb.AppendLine("</table>")
        [void]$sb.AppendLine("<p><em>Yellow = largest cross-host variance. Red = worst scenario for V26.1+Phoenix.</em></p>")

    # ════════════════════════════════════════════════
    # 7. SENSOR CPU - PEAK BY ROLE
    # ════════════════════════════════════════════════
        [void]$sb.AppendLine("<h2>Sensor CPU - Peak by Role</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> The highest instantaneous CPU spike produced by all sensor processes combined during each scenario. This captures worst-case sensor CPU bursts (e.g., during heavy file I/O or process-creation storms) that the averages above would smooth out. Same normalization: per-process <code>% Processor Time</code> summed and divided by number of cores.</div>
"@)
        [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
        foreach ($r in $sensorRoles) { [void]$sb.AppendLine("<th>$r</th>") }
        [void]$sb.AppendLine("</tr>")

        $sensorPeakClasses = @{}
        $maxVar = 0; $maxVarSc = ""; $worstS2Val = [double]::MinValue; $worstS2Sc = ""
        foreach ($sc in $activeSensorScenarios) {
            $vals = @($sensorHosts | ForEach-Object { $h = $_; $e = $sensorVm | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1; if ($e) { [double]$e.peakCpu } else { 0 } })
            $var = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
            if ($var -gt $maxVar) { $maxVar = $var; $maxVarSc = $sc }
            $s2e = $sensorVm | Where-Object { $_.host -eq $s2 -and $_.scenario -eq $sc } | Select-Object -First 1
            $s2v = if ($s2e) { [double]$s2e.peakCpu } else { 0 }
            if ($s2v -gt $worstS2Val) { $worstS2Val = $s2v; $worstS2Sc = $sc }
        }
        foreach ($sc in $activeSensorScenarios) {
            if ($sc -eq $worstS2Sc) { $sensorPeakClasses[$sc] = 'worst-s2-row' }
            elseif ($sc -eq $maxVarSc) { $sensorPeakClasses[$sc] = 'highlight-row' }
            else { $sensorPeakClasses[$sc] = '' }
        }

        foreach ($sc in $allScenarios) {
            if ($sensorScenarios -notcontains $sc) { continue }
            $cls = $sensorPeakClasses[$sc]
            $rowAttr = if ($cls) { " class=`"$cls`"" } else { '' }
            [void]$sb.AppendLine("<tr$rowAttr><td><code>$sc</code></td>")
            foreach ($r in $sensorRoles) {
                $h = Get-HostFromRole $r
                $entry = $sensorVm | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1
                $val = if ($entry) { [double]$entry.peakCpu } else { $null }
                if ($null -ne $val) {
                    $color = Get-CpuColor $val 10 30
                    [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $color; color: white;`">$([math]::Round($val, 1))%</td>")
                } else { [void]$sb.AppendLine("<td class=`"na-cell`" title=`"Scenario did not complete on this host`">N/A</td>") }
            }
            [void]$sb.AppendLine("</tr>")
        }
        [void]$sb.AppendLine("</table>")
        [void]$sb.AppendLine("<p><em>Yellow = largest cross-host variance. Red = worst scenario for V26.1+Phoenix.</em></p>")
    }

    # ════════════════════════════════════════════════
    # 8. SYSTEM MEMORY (Used MB = 4096 - Available)
    # ════════════════════════════════════════════════
    $sysMem = if ($InfluxData -and $InfluxData.systemMem) { $InfluxData.systemMem } else { @() }
    $totalRamMB = 4096
    if ($sysMem.Count -gt 0) {
        [void]$sb.AppendLine("<h2>Total System Memory Usage (All Processes + OS)</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> The total memory consumed by the <em>entire system</em> &mdash; including the operating system, all running services, the sensor (if installed), and the test workload combined. This is <strong>not</strong> sensor-specific memory.<br><br>
<strong>How it's calculated:</strong> Used Memory = Total RAM ($($totalRamMB) MB) minus Available Memory (from Windows <code>win_mem Available_MBytes</code>).<br>
<strong>How to read it:</strong> Compare sensor hosts (S2, S3, S4) vs. baseline (S1) to estimate the sensor's total memory impact on the system. The difference includes sensor process memory, kernel driver allocations, OS caching changes, and other indirect effects.</div>
"@)
        [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
        foreach ($r in $allRoles) { [void]$sb.AppendLine("<th>$r Avg</th><th>$r Peak</th>") }
        [void]$sb.AppendLine("</tr>")
        $memScenarios = @($sysMem | ForEach-Object { $_.scenario } | Sort-Object -Unique)
        $activeMemScenarios = @($allScenarios | Where-Object { $memScenarios -contains $_ })

        $sysMemClasses = @{}
        $maxVar = 0; $maxVarSc = ""; $worstS2Val = [double]::MinValue; $worstS2Sc = ""
        foreach ($sc in $activeMemScenarios) {
            $vals = @($allHosts | ForEach-Object { $h = $_; $e = $sysMem | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1; if ($e) { $totalRamMB - [double]$e.avgAvailableMB } else { 0 } })
            $var = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
            if ($var -gt $maxVar) { $maxVar = $var; $maxVarSc = $sc }
            $s2e = $sysMem | Where-Object { $_.host -eq $s2 -and $_.scenario -eq $sc } | Select-Object -First 1
            $s2v = if ($s2e) { $totalRamMB - [double]$s2e.avgAvailableMB } else { 0 }
            if ($s2v -gt $worstS2Val) { $worstS2Val = $s2v; $worstS2Sc = $sc }
        }
        foreach ($sc in $activeMemScenarios) {
            if ($sc -eq $worstS2Sc) { $sysMemClasses[$sc] = 'worst-s2-row' }
            elseif ($sc -eq $maxVarSc) { $sysMemClasses[$sc] = 'highlight-row' }
            else { $sysMemClasses[$sc] = '' }
        }

        foreach ($sc in $allScenarios) {
            if ($memScenarios -notcontains $sc) { continue }
            $cls = $sysMemClasses[$sc]
            $rowAttr = if ($cls) { " class=`"$cls`"" } else { '' }
            [void]$sb.AppendLine("<tr$rowAttr><td><code>$sc</code></td>")
            foreach ($r in $allRoles) {
                $h = Get-HostFromRole $r
                $entry = $sysMem | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1
                if ($entry) {
                    $avgUsed = [math]::Round($totalRamMB - [double]$entry.avgAvailableMB, 0)
                    $peakAvail = if ($entry.PSObject.Properties['peakAvailableMB']) { [double]$entry.peakAvailableMB } else { [double]$entry.avgAvailableMB }
                    $peakUsed = [math]::Round($totalRamMB - $peakAvail, 0)
                    if ($peakUsed -lt $avgUsed) { $tmp = $peakUsed; $peakUsed = $avgUsed; $avgUsed = $tmp }
                    $avgColor = Get-SysMemColor $avgUsed
                    $peakColor = Get-SysMemColor $peakUsed
                    [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $avgColor; color: white;`">$avgUsed</td>")
                    [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $peakColor; color: white;`">$peakUsed</td>")
                } else { [void]$sb.AppendLine("<td class=`"na-cell`" title=`"Scenario did not complete on this host`">N/A</td><td class=`"na-cell`" title=`"Scenario did not complete on this host`">N/A</td>") }
            }
            [void]$sb.AppendLine("</tr>")
        }
        [void]$sb.AppendLine("</table>")
        [void]$sb.AppendLine("<p><em>Yellow = largest cross-host variance. Red = worst scenario for V26.1+Phoenix.</em></p>")
    }

    # ════════════════════════════════════════════════
    # 9. SENSOR MEMORY (includes kernel pool estimate)
    # ════════════════════════════════════════════════
    $sensorMem = if ($InfluxData -and $InfluxData.sensorMemory) { $InfluxData.sensorMemory } else { @() }
    $kernelPool = if ($InfluxData -and $InfluxData.kernelPoolMB) { $InfluxData.kernelPoolMB } else { @() }
    if ($sensorMem.Count -gt 0) {
        [void]$sb.AppendLine("<h2>Sensor Memory (MB)</h2>")

        $hasKernelPool = ($kernelPool.Count -gt 0)
        if ($hasKernelPool) {
            [void]$sb.AppendLine(@"
<div class="callout"><strong>Memory Definition:</strong> Working Set of all sensor user-mode processes (minionhost, ActiveConsole, PylumLoader, CrsSvc, etc.) summed together, <em>plus</em> an estimate of kernel-mode memory from system pool allocations (Paged + Nonpaged Pool delta vs. baseline). The kernel pool delta is the difference in pool usage between each sensor host and the no-sensor baseline, attributing it to sensor driver activity.</div>
"@)
        } else {
            [void]$sb.AppendLine(@"
<div class="callout"><strong>Memory Definition:</strong> Working Set of all sensor user-mode processes (minionhost, ActiveConsole, PylumLoader, CrsSvc, etc.) summed together. Kernel-mode driver memory (e.g., CrDrv.sys pool allocations) is included via system pool delta when kernel pool data is available.</div>
"@)
        }

        [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
        foreach ($r in $sensorRoles) { [void]$sb.AppendLine("<th>$r Avg</th><th>$r Peak</th>") }
        [void]$sb.AppendLine("</tr>")
        $smScenarios = @($sensorMem | ForEach-Object { $_.scenario } | Sort-Object -Unique)
        $activeSmScenarios = @($allScenarios | Where-Object { $smScenarios -contains $_ })

        $sensorMemClasses = @{}
        $maxVar = 0; $maxVarSc = ""; $worstS2Val = [double]::MinValue; $worstS2Sc = ""
        foreach ($sc in $activeSmScenarios) {
            $vals = @($sensorHosts | ForEach-Object { $h = $_; $e = $sensorMem | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1; if ($e) { [double]$e.avgMemMB } else { 0 } })
            $var = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
            if ($var -gt $maxVar) { $maxVar = $var; $maxVarSc = $sc }
            $s2e = $sensorMem | Where-Object { $_.host -eq $s2 -and $_.scenario -eq $sc } | Select-Object -First 1
            $s2v = if ($s2e -and $s2e.PSObject.Properties['peakMemMB']) { [double]$s2e.peakMemMB } elseif ($s2e) { [double]$s2e.avgMemMB } else { 0 }
            if ($s2v -gt $worstS2Val) { $worstS2Val = $s2v; $worstS2Sc = $sc }
        }
        foreach ($sc in $activeSmScenarios) {
            if ($sc -eq $worstS2Sc) { $sensorMemClasses[$sc] = 'worst-s2-row' }
            elseif ($sc -eq $maxVarSc) { $sensorMemClasses[$sc] = 'highlight-row' }
            else { $sensorMemClasses[$sc] = '' }
        }

        foreach ($sc in $allScenarios) {
            if ($smScenarios -notcontains $sc) { continue }
            $cls = $sensorMemClasses[$sc]
            $rowAttr = if ($cls) { " class=`"$cls`"" } else { '' }
            [void]$sb.AppendLine("<tr$rowAttr><td><code>$sc</code></td>")
            foreach ($r in $sensorRoles) {
                $h = Get-HostFromRole $r
                $entry = $sensorMem | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1
                if ($entry) {
                    $avg = [math]::Round([double]$entry.avgMemMB, 1)
                    $peak = if ($entry.PSObject.Properties['peakMemMB']) { [math]::Round([double]$entry.peakMemMB, 1) } else { $avg }

                    # Add kernel pool delta if available
                    if ($hasKernelPool) {
                        $baseKp = $kernelPool | Where-Object { $_.host -eq $s1 -and $_.scenario -eq $sc } | Select-Object -First 1
                        $hostKp = $kernelPool | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1
                        if ($baseKp -and $hostKp) {
                            $kpAvgDelta = ([double]$hostKp.avgPagedMB + [double]$hostKp.avgNonpagedMB) - ([double]$baseKp.avgPagedMB + [double]$baseKp.avgNonpagedMB)
                            $kpPeakDelta = ([double]$hostKp.peakPagedMB + [double]$hostKp.peakNonpagedMB) - ([double]$baseKp.peakPagedMB + [double]$baseKp.peakNonpagedMB)
                            if ($kpAvgDelta -gt 0) { $avg = [math]::Round($avg + $kpAvgDelta, 1) }
                            if ($kpPeakDelta -gt 0) { $peak = [math]::Round($peak + $kpPeakDelta, 1) }
                        }
                    }

                    [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $(Get-MemColor $avg); color: white;`">$avg</td>")
                    [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $(Get-MemColor $peak); color: white;`">$peak</td>")
                } else { [void]$sb.AppendLine("<td class=`"na-cell`" title=`"Scenario did not complete on this host`">N/A</td><td class=`"na-cell`" title=`"Scenario did not complete on this host`">N/A</td>") }
            }
            [void]$sb.AppendLine("</tr>")
        }
        [void]$sb.AppendLine("</table>")
        [void]$sb.AppendLine("<p><em>Yellow = largest cross-host variance. Red = worst scenario for V26.1+Phoenix (peak).</em></p>")
    }

    # ════════════════════════════════════════════════
    # 10. SENSOR PROCESS UPTIME & DB SIZE
    # ════════════════════════════════════════════════
    if ($InfluxData -and $InfluxData.sensorLivenessUptime -and $InfluxData.sensorLivenessUptime.Count -gt 0) {
        $sensorHostsUptime = @($InfluxData.sensorLivenessUptime | Where-Object { [double]$_.minionhost_uptime -gt 0 -or [double]$_.activeconsole_uptime -gt 0 })
        if ($sensorHostsUptime.Count -gt 0) {
            [void]$sb.AppendLine("<h2>Sensor Process Uptime &amp; DB Size</h2>")
            [void]$sb.AppendLine(@"
<div class="callout">
<strong>Uptime:</strong> Percentage of Telegraf collection intervals where the process was detected as running, measured across the entire test duration (all scenarios). 100% = process never crashed or restarted.<br>
<strong>Restarts:</strong> Number of times the process was detected as restarting (went from down to up) during the test run. 0 = no restarts detected.<br>
<strong>DB Size:</strong> Last observed size of the sensor's local database file on disk at the end of the test run.
</div>
"@)
            [void]$sb.AppendLine("<table><tr><th>Role</th><th>MinionHost Uptime</th><th>MinionHost Restarts</th><th>ActiveConsole Uptime</th><th>ActiveConsole Restarts</th><th>DB Size</th></tr>")
            foreach ($l in $sensorHostsUptime) {
                $mh = "$([math]::Round([double]$l.minionhost_uptime, 1))%"
                $ac = "$([math]::Round([double]$l.activeconsole_uptime, 1))%"
                $mhR = 0; try { if ($l.minionhost_restarts -ne $null) { $mhR = [int]$l.minionhost_restarts } } catch {}
                $acR = 0; try { if ($l.activeconsole_restarts -ne $null) { $acR = [int]$l.activeconsole_restarts } } catch {}
                $mhRColor = if ($mhR -eq 0) { "#27ae60" } elseif ($mhR -le 2) { "#f39c12" } else { "#e74c3c" }
                $acRColor = if ($acR -eq 0) { "#27ae60" } elseif ($acR -le 2) { "#f39c12" } else { "#e74c3c" }
                $db = $InfluxData.sensorDbSize | Where-Object { $_.host -eq $l.host } | Select-Object -First 1
                $dbStr = if ($db) { "$([math]::Round([long]$db.sizeBytes / 1MB, 1)) MB" } else { "N/A" }
                [void]$sb.AppendLine("<tr><td>$(Get-Role $l.host)</td><td class=`"numeric`">$mh</td><td class=`"numeric`" style=`"background-color: $mhRColor; color: white;`">$mhR</td><td class=`"numeric`">$ac</td><td class=`"numeric`" style=`"background-color: $acRColor; color: white;`">$acR</td><td class=`"numeric`">$dbStr</td></tr>")
            }
            [void]$sb.AppendLine("</table>")
        }
    }

    # ════════════════════════════════════════════════
    # 11. DISK I/O (all scenarios, highlight max variance + worst S2)
    # ════════════════════════════════════════════════
    $disk = if ($InfluxData -and $InfluxData.diskIo) { $InfluxData.diskIo } else { @() }
    if ($disk.Count -gt 0) {
        [void]$sb.AppendLine("<h2>Disk I/O (Write KB/s)</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> Average disk write throughput in KB/s per host during each scenario. Higher values on sensor hosts vs baselines indicate sensor-induced disk overhead (database writes, event logging, etc.).</div>
"@)
        $diskScenarios = @($disk | ForEach-Object { $_.scenario } | Sort-Object -Unique)
        $activeDiskScenarios = @($allScenarios | Where-Object { $diskScenarios -contains $_ })

        $diskClasses = @{}
        $maxDiskVariance = 0; $maxDiskVarScenario = ""; $worstS2Val = [double]::MinValue; $worstS2Sc = ""
        foreach ($sc in $activeDiskScenarios) {
            $vals = @($allHosts | ForEach-Object { $h = $_; $e = $disk | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1; if ($e) { [double]$e.writeBps / 1024 } else { 0 } })
            $variance = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
            if ($variance -gt $maxDiskVariance) { $maxDiskVariance = $variance; $maxDiskVarScenario = $sc }
            $s2e = $disk | Where-Object { $_.host -eq $s2 -and $_.scenario -eq $sc } | Select-Object -First 1
            $s2v = if ($s2e) { [double]$s2e.writeBps / 1024 } else { 0 }
            if ($s2v -gt $worstS2Val) { $worstS2Val = $s2v; $worstS2Sc = $sc }
        }
        foreach ($sc in $activeDiskScenarios) {
            if ($sc -eq $worstS2Sc) { $diskClasses[$sc] = 'worst-s2-row' }
            elseif ($sc -eq $maxDiskVarScenario) { $diskClasses[$sc] = 'highlight-row' }
            else { $diskClasses[$sc] = '' }
        }

        [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
        foreach ($r in $allRoles) { [void]$sb.AppendLine("<th>$r</th>") }
        [void]$sb.AppendLine("</tr>")
        foreach ($sc in $allScenarios) {
            if ($diskScenarios -notcontains $sc) { continue }
            $cls = $diskClasses[$sc]
            $rowAttr = if ($cls) { " class=`"$cls`"" } else { '' }
            [void]$sb.AppendLine("<tr$rowAttr><td><code>$sc</code></td>")
            foreach ($r in $allRoles) {
                $h = Get-HostFromRole $r
                $entry = $disk | Where-Object { $_.host -eq $h -and $_.scenario -eq $sc } | Select-Object -First 1
                if ($entry) {
                    $val = [math]::Round([double]$entry.writeBps / 1024, 1)
                    [void]$sb.AppendLine("<td class=`"numeric`">$val</td>")
                } else {
                    [void]$sb.AppendLine("<td class=`"na-cell`" title=`"Scenario did not complete on this host`">N/A</td>")
                }
            }
            [void]$sb.AppendLine("</tr>")
        }
        [void]$sb.AppendLine("</table>")
        [void]$sb.AppendLine("<p><em>Yellow = largest cross-host variance. Red = worst scenario for V26.1+Phoenix.</em></p>")
    }

    # ════════════════════════════════════════════════
    # 12. PROCESS CPU/MEMORY IMPACT BY SCENARIO (before Bottom Line)
    # ════════════════════════════════════════════════
    $sysProc = if ($InfluxData -and $InfluxData.systemProcessCpu) { $InfluxData.systemProcessCpu } else { @() }
    $sysProcMem = if ($InfluxData -and $InfluxData.systemProcessMemory) { $InfluxData.systemProcessMemory } else { @() }
    $hasProcessMem = $sysProcMem.Count -gt 0
    if ($sysProc.Count -gt 0) {
        [void]$sb.AppendLine("<h2>Process CPU/Memory Impact by Scenario</h2>")
        [void]$sb.AppendLine(@"
<div class="callout">
<strong>How it's calculated:</strong> CPU% = Windows &lsquo;% Processor Time&rsquo; for each process, divided by $NumCores cores. Mem(MB) = process Working Set in megabytes. All monitored processes are shown for each scenario (sensor processes listed first, then OS processes). A <strong>Total</strong> row aggregates CPU (sum) and Memory (sum) per host.<br>
<strong>Color coding &mdash; CPU:</strong> <span style="background:#27ae60;color:white;padding:2px 6px;border-radius:3px;">Green</span> &lt; 1%, <span style="background:#f39c12;color:white;padding:2px 6px;border-radius:3px;">Yellow</span> 1&ndash;5%, <span style="background:#e74c3c;color:white;padding:2px 6px;border-radius:3px;">Red</span> &gt; 5%. <strong>Memory:</strong> <span style="background:#1e8449;color:white;padding:2px 6px;border-radius:3px;">Green</span> &lt; 50 MB, <span style="background:#d68910;color:white;padding:2px 6px;border-radius:3px;">Yellow</span> 50&ndash;200 MB, <span style="background:#c0392b;color:white;padding:2px 6px;border-radius:3px;">Red</span> &gt; 200 MB.<br>
The scenario with the largest cross-host total CPU variance is highlighted in yellow.
</div>
"@)

        $procScenarios = @($sysProc | ForEach-Object { $_.scenario } | Sort-Object -Unique)
        $sensorProcessNames = @("minionhost", "ActiveConsole", "CrsSvc", "PylumLoader", "AmSvc", "WscIfSvc", "ExecutionPreventionSvc", "CrAmTray", "Nnx", "CrDrvCtrl")

        $scenarioVariance = @{}
        foreach ($sc in $procScenarios) {
            $scEntries = @($sysProc | Where-Object { $_.scenario -eq $sc })
            $maxVal = 0; $minVal = [double]::MaxValue
            foreach ($h in $allHosts) {
                $hostTotal = 0; $scEntries | Where-Object { $_.host -eq $h } | ForEach-Object { $hostTotal += [double]$_.avgCpu }
                if ($hostTotal -gt $maxVal) { $maxVal = $hostTotal }
                if ($hostTotal -lt $minVal) { $minVal = $hostTotal }
            }
            $scenarioVariance[$sc] = $maxVal - $minVal
        }
        $maxVarScenario = ($scenarioVariance.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key

        foreach ($sc in $allScenarios) {
            if ($procScenarios -notcontains $sc) { continue }
            $scEntries = @($sysProc | Where-Object { $_.scenario -eq $sc })
            $scMemEntries = @($sysProcMem | Where-Object { $_.scenario -eq $sc })
            $allProcsInScenario = @($scEntries | ForEach-Object { $_.process } | Sort-Object -Unique)
            if ($hasProcessMem) {
                $memProcs = @($scMemEntries | ForEach-Object { $_.process } | Sort-Object -Unique)
                $allProcsInScenario = @($allProcsInScenario + $memProcs | Sort-Object -Unique)
            }

            $sensorProcsPresent = @($allProcsInScenario | Where-Object { $sensorProcessNames -contains $_ } | Sort-Object)
            $osProcsPresent = @($allProcsInScenario | Where-Object { $sensorProcessNames -notcontains $_ } | Sort-Object)
            $sortedProcs = @($sensorProcsPresent) + @($osProcsPresent)

            if ($sortedProcs.Count -eq 0) { continue }

            $scHighlight = if ($sc -eq $maxVarScenario) { ' style="border: 2px solid #f39c12; padding: 4px; background: #fef9e7;"' } else { '' }
            [void]$sb.AppendLine("<h3$scHighlight><code>$sc</code>$(if ($sc -eq $maxVarScenario) { ' (largest cross-host variance)' } else { '' })</h3>")

            $colsPerHost = if ($hasProcessMem) { 2 } else { 2 }
            [void]$sb.AppendLine("<table>")
            # Row 1: grouped host headers
            [void]$sb.AppendLine("<tr class=`"group-header`"><th rowspan=`"2`">Process</th>")
            $hostIdx = 0
            foreach ($hn in $allHosts) {
                $rn = if ($roleMap[$hn]) { $roleMap[$hn] } else { $hn }
                $sepStyle = if ($hostIdx -gt 0) { ' class="vm-separator"' } else { '' }
                if ($hasProcessMem) {
                    [void]$sb.AppendLine("<th colspan=`"2`"$sepStyle>$rn Avg</th><th colspan=`"2`">$rn Peak</th>")
                } else {
                    [void]$sb.AppendLine("<th$sepStyle>$rn Avg</th><th>$rn Peak</th>")
                }
                $hostIdx++
            }
            [void]$sb.AppendLine("</tr>")
            # Row 2: metric sub-headers
            if ($hasProcessMem) {
                [void]$sb.AppendLine("<tr class=`"sub-header`">")
                $hostIdx = 0
                foreach ($hn in $allHosts) {
                    $sepClass = if ($hostIdx -gt 0) { ' class="vm-separator"' } else { '' }
                    [void]$sb.AppendLine("<th$sepClass>CPU%</th><th>Mem(MB)</th><th>CPU%</th><th>Mem(MB)</th>")
                    $hostIdx++
                }
                [void]$sb.AppendLine("</tr>")
            }

            $hostTotals = @{}
            foreach ($hn in $allHosts) { $hostTotals[$hn] = @{ avgCpu = 0.0; peakCpu = 0.0; avgMem = 0.0; peakMem = 0.0 } }

            foreach ($proc in $sortedProcs) {
                [void]$sb.AppendLine("<tr><td><code>$proc</code></td>")
                $hostIdx = 0
                foreach ($hn in $allHosts) {
                    $cpuEntry = $scEntries | Where-Object { $_.host -eq $hn -and $_.process -eq $proc } | Select-Object -First 1
                    $memEntry = if ($hasProcessMem) { $scMemEntries | Where-Object { $_.host -eq $hn -and $_.process -eq $proc } | Select-Object -First 1 } else { $null }
                    $sepClass = if ($hostIdx -gt 0) { ' vm-separator' } else { '' }

                    $avgCpu = if ($cpuEntry) { [math]::Round([double]$cpuEntry.avgCpu, 1) } else { 0 }
                    $peakCpu = if ($cpuEntry -and $cpuEntry.PSObject.Properties['peakCpu']) { [math]::Round([double]$cpuEntry.peakCpu, 1) } elseif ($cpuEntry) { $avgCpu } else { 0 }
                    $avgMem = if ($memEntry) { [math]::Round([double]$memEntry.avgMemMB, 1) } else { 0 }
                    $peakMem = if ($memEntry -and $memEntry.PSObject.Properties['peakMemMB']) { [math]::Round([double]$memEntry.peakMemMB, 1) } elseif ($memEntry) { $avgMem } else { 0 }

                    $hostTotals[$hn].avgCpu += $avgCpu
                    $hostTotals[$hn].peakCpu += $peakCpu
                    $hostTotals[$hn].avgMem += $avgMem
                    $hostTotals[$hn].peakMem += $peakMem

                    $avgCpuColor = Get-CpuColor $avgCpu 1 5
                    $peakCpuColor = Get-CpuColor $peakCpu 2 10
                    $avgMemColor = Get-ProcMemColor $avgMem
                    $peakMemColor = Get-ProcMemColor $peakMem

                    if ($hasProcessMem) {
                        [void]$sb.AppendLine("<td class=`"cpu-cell$sepClass`" style=`"background-color: $avgCpuColor; color: white;`">$avgCpu</td>")
                        [void]$sb.AppendLine("<td class=`"mem-cell`" style=`"background-color: $avgMemColor; color: white;`">$avgMem</td>")
                        [void]$sb.AppendLine("<td class=`"cpu-cell`" style=`"background-color: $peakCpuColor; color: white;`">$peakCpu</td>")
                        [void]$sb.AppendLine("<td class=`"mem-cell`" style=`"background-color: $peakMemColor; color: white;`">$peakMem</td>")
                    } else {
                        [void]$sb.AppendLine("<td class=`"cpu-cell$sepClass`" style=`"background-color: $avgCpuColor; color: white;`">$avgCpu</td>")
                        [void]$sb.AppendLine("<td class=`"cpu-cell`" style=`"background-color: $peakCpuColor; color: white;`">$peakCpu</td>")
                    }
                    $hostIdx++
                }
                [void]$sb.AppendLine("</tr>")
            }

            # TOTAL row
            [void]$sb.AppendLine("<tr class=`"total-row`"><td><strong>TOTAL</strong></td>")
            $hostIdx = 0
            foreach ($hn in $allHosts) {
                $sepClass = if ($hostIdx -gt 0) { ' vm-separator' } else { '' }
                $tAvgCpu = [math]::Round($hostTotals[$hn].avgCpu, 1)
                $tPeakCpu = [math]::Round($hostTotals[$hn].peakCpu, 1)
                $tAvgMem = [math]::Round($hostTotals[$hn].avgMem, 1)
                $tPeakMem = [math]::Round($hostTotals[$hn].peakMem, 1)
                if ($hasProcessMem) {
                    [void]$sb.AppendLine("<td class=`"cpu-cell$sepClass`"><strong>$tAvgCpu</strong></td><td class=`"mem-cell`"><strong>$tAvgMem</strong></td>")
                    [void]$sb.AppendLine("<td class=`"cpu-cell`"><strong>$tPeakCpu</strong></td><td class=`"mem-cell`"><strong>$tPeakMem</strong></td>")
                } else {
                    [void]$sb.AppendLine("<td class=`"cpu-cell$sepClass`"><strong>$tAvgCpu</strong></td><td class=`"cpu-cell`"><strong>$tPeakCpu</strong></td>")
                }
                $hostIdx++
            }
            [void]$sb.AppendLine("</tr>")
            [void]$sb.AppendLine("</table>")
        }
    }

    # ════════════════════════════════════════════════
    # 13. BOTTOM LINE (key findings focused on V26.1+Phoenix)
    # ════════════════════════════════════════════════
    [void]$sb.AppendLine("<h2>Bottom Line</h2>")
    [void]$sb.AppendLine('<div class="bottom-line">')

    if ($InfluxData) {
        # --- Memory findings ---

        # Sensor process memory (Working Set) for V26.1+Phoenix
        $avgSensorMem = 0; $peakSensorMem = 0; $peakSensorSc = ""
        if ($sensorMem.Count -gt 0) {
            $s2MemAll = @($sensorMem | Where-Object { $_.host -eq $s2 })
            if ($s2MemAll.Count -gt 0) {
                $sumAvg = 0; $s2MemAll | ForEach-Object { $sumAvg += [double]$_.avgMemMB }
                $avgSensorMem = [math]::Round($sumAvg / $s2MemAll.Count, 0)
                foreach ($m in $s2MemAll) {
                    $pk = if ($m.PSObject.Properties['peakMemMB']) { [double]$m.peakMemMB } else { [double]$m.avgMemMB }
                    if ($pk -gt $peakSensorMem) { $peakSensorMem = $pk; $peakSensorSc = $m.scenario }
                }
            }
        }

        # System-level memory overhead: all versions vs baseline (avg + peak)
        $avgMemOh = 0; $avgS3Oh = 0; $avgS4Oh = 0
        $peakMemOh = 0; $peakMemOhSc = ""; $peakS3Oh = 0; $peakS3OhSc = ""; $peakS4Oh = 0; $peakS4OhSc = ""
        if ($sysMem.Count -gt 0) {
            $s2MemOverheadAvg = @(); $s3MemOverheadAvg = @(); $s4MemOverheadAvg = @()
            foreach ($sc in $allScenarios) {
                $baseEntry = $sysMem | Where-Object { $_.host -eq $s1 -and $_.scenario -eq $sc } | Select-Object -First 1
                $s2Entry = $sysMem | Where-Object { $_.host -eq $s2 -and $_.scenario -eq $sc } | Select-Object -First 1
                $s3Entry = $sysMem | Where-Object { $_.host -eq $s3 -and $_.scenario -eq $sc } | Select-Object -First 1
                $s4Entry = $sysMem | Where-Object { $_.host -eq $s4 -and $_.scenario -eq $sc } | Select-Object -First 1
                if ($baseEntry -and $s2Entry) {
                    $baseUsedAvg = $totalRamMB - [double]$baseEntry.avgAvailableMB
                    $s2UsedAvg = $totalRamMB - [double]$s2Entry.avgAvailableMB
                    $oh = [math]::Round($s2UsedAvg - $baseUsedAvg, 0)
                    $s2MemOverheadAvg += [PSCustomObject]@{ Scenario = $sc; OverheadMB = $oh }
                    if ($oh -gt $peakMemOh) { $peakMemOh = $oh; $peakMemOhSc = $sc }
                }
                if ($baseEntry -and $s3Entry) {
                    $oh3 = [math]::Round(($totalRamMB - [double]$s3Entry.avgAvailableMB) - ($totalRamMB - [double]$baseEntry.avgAvailableMB), 0)
                    $s3MemOverheadAvg += [PSCustomObject]@{ Scenario = $sc; OverheadMB = $oh3 }
                    if ($oh3 -gt $peakS3Oh) { $peakS3Oh = $oh3; $peakS3OhSc = $sc }
                }
                if ($baseEntry -and $s4Entry) {
                    $oh4 = [math]::Round(($totalRamMB - [double]$s4Entry.avgAvailableMB) - ($totalRamMB - [double]$baseEntry.avgAvailableMB), 0)
                    $s4MemOverheadAvg += [PSCustomObject]@{ Scenario = $sc; OverheadMB = $oh4 }
                    if ($oh4 -gt $peakS4Oh) { $peakS4Oh = $oh4; $peakS4OhSc = $sc }
                }
            }
            if ($s2MemOverheadAvg.Count -gt 0) { $avgMemOh = [math]::Round(($s2MemOverheadAvg | Measure-Object -Property OverheadMB -Average).Average, 0) }
            if ($s3MemOverheadAvg.Count -gt 0) { $avgS3Oh = [math]::Round(($s3MemOverheadAvg | Measure-Object -Property OverheadMB -Average).Average, 0) }
            if ($s4MemOverheadAvg.Count -gt 0) { $avgS4Oh = [math]::Round(($s4MemOverheadAvg | Measure-Object -Property OverheadMB -Average).Average, 0) }
        }

        # Sensor memory for S3 and S4 for comparison
        $avgS3SenMem = 0; $peakS3SenMem = 0; $peakS3SenSc = ""
        $avgS4SenMem = 0; $peakS4SenMem = 0; $peakS4SenSc = ""
        $s3MemAll = @($sensorMem | Where-Object { $_.host -eq $s3 })
        if ($s3MemAll.Count -gt 0) {
            $sum3 = 0; $s3MemAll | ForEach-Object { $sum3 += [double]$_.avgMemMB }
            $avgS3SenMem = [math]::Round($sum3 / $s3MemAll.Count, 0)
            foreach ($m in $s3MemAll) { $pk = if ($m.PSObject.Properties['peakMemMB']) { [double]$m.peakMemMB } else { [double]$m.avgMemMB }; if ($pk -gt $peakS3SenMem) { $peakS3SenMem = $pk; $peakS3SenSc = $m.scenario } }
        }
        $s4MemAll = @($sensorMem | Where-Object { $_.host -eq $s4 })
        if ($s4MemAll.Count -gt 0) {
            $sum4 = 0; $s4MemAll | ForEach-Object { $sum4 += [double]$_.avgMemMB }
            $avgS4SenMem = [math]::Round($sum4 / $s4MemAll.Count, 0)
            foreach ($m in $s4MemAll) { $pk = if ($m.PSObject.Properties['peakMemMB']) { [double]$m.peakMemMB } else { [double]$m.avgMemMB }; if ($pk -gt $peakS4SenMem) { $peakS4SenMem = $pk; $peakS4SenSc = $m.scenario } }
        }

        [void]$sb.AppendLine(@"
<div class="finding"><strong>Memory Impact &mdash; V26.1 + Phoenix:</strong><br>
&bull; <strong>Sensor process memory (Working Set):</strong> V26.1+Phoenix sensor processes consume an average of <strong>$avgSensorMem MB</strong> across all scenarios, peaking at <strong>$([math]::Round($peakSensorMem, 0)) MB</strong> during <code>$peakSensorSc</code>.<br>
&bull; <strong>Comparison across versions (sensor Working Set):</strong> V26.1+Phoenix: avg <strong>$avgSensorMem MB</strong> / peak <strong>$([math]::Round($peakSensorMem, 0)) MB</strong> | V26.1+Legacy: avg <strong>$avgS3SenMem MB</strong> / peak <strong>$([math]::Round($peakS3SenMem, 0)) MB</strong>$(if ($peakS3SenSc) { " (<code>$peakS3SenSc</code>)" }) | V24.1+Legacy: avg <strong>$avgS4SenMem MB</strong> / peak <strong>$([math]::Round($peakS4SenMem, 0)) MB</strong>$(if ($peakS4SenSc) { " (<code>$peakS4SenSc</code>)" }).<br>
&bull; <strong>System-level memory overhead vs. baseline:</strong> Total OS-reported available memory delta (S2 minus S1) shows avg <strong>$avgMemOh MB</strong>, peak <strong>$peakMemOh MB</strong> during <code>$peakMemOhSc</code>. <em>Note:</em> This metric is <strong>noisy</strong> &mdash; it reflects the net effect of the sensor, OS file cache, and workload differences across VMs. Negative values mean the sensor host had <em>more</em> free memory than the baseline, typically because the workload itself consumed more OS cache on the baseline VM. The sensor Working Set numbers above are a more reliable measure of sensor memory consumption.</div>
"@)

        # --- CPU findings ---
        $avgS2Cpu = 0; $avgS3Cpu = 0; $avgS4Cpu = 0
        if ($sensorVm.Count -gt 0) {
            $s2CpuAvgAll = @($sensorVm | Where-Object { $_.host -eq $s2 })
            $s3CpuAvgAll = @($sensorVm | Where-Object { $_.host -eq $s3 })
            $s4CpuAvgAll = @($sensorVm | Where-Object { $_.host -eq $s4 })
            $avgS2Cpu = if ($s2CpuAvgAll.Count -gt 0) { $sum = 0; $s2CpuAvgAll | ForEach-Object { $sum += [double]$_.avgCpu }; [math]::Round($sum / $s2CpuAvgAll.Count, 1) } else { 0 }
            $avgS3Cpu = if ($s3CpuAvgAll.Count -gt 0) { $sum = 0; $s3CpuAvgAll | ForEach-Object { $sum += [double]$_.avgCpu }; [math]::Round($sum / $s3CpuAvgAll.Count, 1) } else { 0 }
            $avgS4Cpu = if ($s4CpuAvgAll.Count -gt 0) { $sum = 0; $s4CpuAvgAll | ForEach-Object { $sum += [double]$_.avgCpu }; [math]::Round($sum / $s4CpuAvgAll.Count, 1) } else { 0 }
            $peakS2 = if ($s2CpuAvgAll.Count -gt 0) { $s2CpuAvgAll | Sort-Object -Property { [double]$_.peakCpu } -Descending | Select-Object -First 1 } else { $null }
            $peakS2Val = if ($peakS2) { [math]::Round([double]$peakS2.peakCpu, 1) } else { 0 }
            $peakS2Sc = if ($peakS2) { $peakS2.scenario } else { "" }

            $cpuComparison = ""
            if ($avgS4Cpu -gt 0 -and $avgS2Cpu -gt 0) {
                $cpuComparison = "<br>&bull; <strong>Comparison across versions (avg sensor CPU):</strong> V26.1+Phoenix: <strong>$avgS2Cpu%</strong>"
                if ($avgS3Cpu -gt 0) { $cpuComparison += " | V26.1+Legacy: <strong>$avgS3Cpu%</strong>" }
                $cpuComparison += " | V24.1+Legacy: <strong>$avgS4Cpu%</strong>."
                if ($avgS2Cpu -lt $avgS4Cpu) {
                    $pctVs24 = [math]::Round((1 - $avgS2Cpu / $avgS4Cpu) * 100, 0)
                    $cpuComparison += " V26.1+Phoenix uses <strong>$pctVs24% less</strong> CPU than V24.1+Legacy."
                } elseif ($avgS2Cpu -gt $avgS4Cpu) {
                    $pctVs24 = [math]::Round(($avgS2Cpu / $avgS4Cpu - 1) * 100, 0)
                    $cpuComparison += " V26.1+Phoenix uses <strong>$pctVs24% more</strong> CPU than V24.1+Legacy."
                }
            }

            [void]$sb.AppendLine("<div class=`"finding`"><strong>CPU Impact &mdash; V26.1 + Phoenix:</strong><br>&bull; Sensor processes average <strong>$avgS2Cpu%</strong> CPU across all scenarios, peaking at <strong>$peakS2Val%</strong> during <code>$peakS2Sc</code>.$cpuComparison</div>")

            # Heaviest process: V26.1+Phoenix first, then Nnx
            if ($sysProc.Count -gt 0) {
                $s2Heaviest = @($sysProc | Where-Object { $_.host -eq $s2 } | Sort-Object -Property { [double]$_.avgCpu } -Descending)
                if ($s2Heaviest.Count -gt 0) {
                    $topS2 = $s2Heaviest[0]
                    [void]$sb.AppendLine("<div class=`"finding`"><strong>Heaviest Process on V26.1 + Phoenix:</strong> <code>$($topS2.process)</code> during <code>$($topS2.scenario)</code> averaged <strong>$([math]::Round([double]$topS2.avgCpu, 1))%</strong> CPU (peak: $([math]::Round([double]$topS2.peakCpu, 1))%).</div>")
                }

                $nnxEntries = @($sysProc | Where-Object { $_.process -eq "Nnx" -and [double]$_.avgCpu -gt 1 })
                if ($nnxEntries.Count -gt 0) {
                    $worstNnx = $nnxEntries | Sort-Object -Property { [double]$_.avgCpu } -Descending | Select-Object -First 1
                    [void]$sb.AppendLine("<div class=`"finding`"><strong>Nnx Process Impact:</strong> Nnx is a file-monitoring component present in all sensor versions. During <code>$($worstNnx.scenario)</code>, Nnx averaged <strong>$([math]::Round([double]$worstNnx.avgCpu, 1))%</strong> CPU (peak: $([math]::Round([double]$worstNnx.peakCpu, 1))%). Nnx reacts heavily to file I/O and can continue processing its backlog long after the workload ends, consuming significant CPU.</div>")
                }
            }

            # Version improvement
            if ($avgS2Cpu -gt 0 -and $avgS4Cpu -gt 0) {
                $improvement = [math]::Round($avgS4Cpu - $avgS2Cpu, 1)
                if ($improvement -gt 0) {
                    $pctImprovement = [math]::Round(($improvement / $avgS4Cpu) * 100, 0)
                    [void]$sb.AppendLine("<div class=`"finding`"><strong>Version Improvement (V26.1 vs V24.1):</strong> V26.1+Phoenix uses <strong>$improvement%</strong> less sensor CPU on average than V24.1+Legacy (a <strong>$pctImprovement%</strong> reduction).</div>")
                }
            }
        }
    } else {
        [void]$sb.AppendLine("<p>No data available for bottom line analysis.</p>")
    }
    [void]$sb.AppendLine("</div>")

    # ════════════════════════════════════════════════
    # 14. CONCLUSIONS
    # ════════════════════════════════════════════════
    [void]$sb.AppendLine("<h2>Conclusions</h2>")
    [void]$sb.AppendLine("<ul>")

    if ($InfluxData) {
        $s2PeakScenarios = @($sensorVm | Where-Object { $_.host -eq $s2 -and [double]$_.peakCpu -gt 15 } | Sort-Object -Property { [double]$_.peakCpu } -Descending)
        if ($s2PeakScenarios.Count -gt 0) {
            $scList = ($s2PeakScenarios | Select-Object -First 3 | ForEach-Object { "<code>$($_.scenario)</code> ($([math]::Round([double]$_.peakCpu, 1))%)" }) -join ", "
            [void]$sb.AppendLine("<li><strong>CPU:</strong> V26.1+Phoenix sensor CPU peaks above 15% in: $scList.</li>")
        } else {
            [void]$sb.AppendLine("<li><strong>CPU:</strong> V26.1+Phoenix sensor CPU remains under 15% peak across all tested scenarios, confirming acceptable CPU overhead.</li>")
        }

        $memConclusion = "<li><strong>Memory:</strong> V26.1+Phoenix sensor process Working Set: avg <strong>$avgSensorMem MB</strong>, peak <strong>$([math]::Round($peakSensorMem, 0)) MB</strong>"
        if ($avgS3SenMem -gt 0 -or $avgS4SenMem -gt 0) {
            $memConclusion += ". Comparison: V26.1+Legacy avg <strong>$avgS3SenMem MB</strong> / peak <strong>$([math]::Round($peakS3SenMem, 0)) MB</strong>, V24.1+Legacy avg <strong>$avgS4SenMem MB</strong> / peak <strong>$([math]::Round($peakS4SenMem, 0)) MB</strong>"
            if ($avgSensorMem -lt $avgS3SenMem -and $avgSensorMem -lt $avgS4SenMem) {
                $memConclusion += " &mdash; Phoenix has the lowest sensor memory footprint."
            }
        }
        $memConclusion += "</li>"
        [void]$sb.AppendLine($memConclusion)

        $nnxHigh = @($sysProc | Where-Object { $_.process -eq "Nnx" -and [double]$_.avgCpu -gt 5 })
        if ($nnxHigh.Count -gt 0) {
            [void]$sb.AppendLine("<li><strong>Nnx Component:</strong> The Nnx file-monitoring component (present in all versions) consumes significant CPU during file-heavy workloads and can continue processing its backlog after workloads end.</li>")
        }

        if ($avgS3Cpu -gt 0 -and $avgS2Cpu -gt 0) {
            $backDiff = [math]::Round($avgS3Cpu - $avgS2Cpu, 1)
            if ($backDiff -gt 2) {
                [void]$sb.AppendLine("<li><strong>Backend:</strong> Phoenix backend shows <strong>$backDiff%</strong> lower average sensor CPU than Legacy backend on the same sensor version (V26.1).</li>")
            } elseif ($backDiff -lt -2) {
                [void]$sb.AppendLine("<li><strong>Backend:</strong> Legacy backend shows <strong>$([math]::Abs($backDiff))%</strong> lower sensor CPU than Phoenix.</li>")
            } else {
                [void]$sb.AppendLine("<li><strong>Backend:</strong> No significant CPU difference between Phoenix and Legacy backends.</li>")
            }
        }

        $scenariosRun = @($sensorVm | ForEach-Object { $_.scenario } | Select-Object -Unique)
        [void]$sb.AppendLine("<li><strong>Test Coverage:</strong> $($scenariosRun.Count) out of 13 scenarios completed across sensor hosts. $(if ($scenariosRun.Count -lt 13) { 'Some sensor hosts did not complete file-heavy scenarios due to Nnx CPU overload (see N/A values).' } else { 'All scenarios completed successfully.' })</li>")

        if ($maxDiskVarScenario) {
            [void]$sb.AppendLine("<li><strong>Disk I/O:</strong> Largest write throughput difference between sensor and baseline hosts observed during <code>$maxDiskVarScenario</code>.</li>")
        }
    } else {
        [void]$sb.AppendLine("<li>No InfluxDB data available for conclusions.</li>")
    }

    [void]$sb.AppendLine("</ul>")
    [void]$sb.AppendLine("</body></html>")
    return $sb.ToString()
}

# ── Build self-service report from scenario result JSONs ──

function Build-SelfServiceReport {
    param(
        [string]$ResultsDir,
        [int]$NumCores = 0
    )

    $jsonFiles = Get-ChildItem -Path $ResultsDir -Filter "*.json" -File | Sort-Object Name
    if ($jsonFiles.Count -eq 0) {
        throw "No scenario JSON files found in $ResultsDir"
    }

    $scenarioResults = @()
    foreach ($f in $jsonFiles) {
        $data = $null
        for ($retry = 0; $retry -lt 5; $retry++) {
            try {
                $fs = [System.IO.FileStream]::new($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $sr = [System.IO.StreamReader]::new($fs)
                $raw = $sr.ReadToEnd()
                $sr.Close(); $fs.Close()
                $data = $raw | ConvertFrom-Json
                break
            } catch {
                if ($retry -lt 4) { Start-Sleep -Seconds 2 } else { throw }
            }
        }
        $scenarioResults += $data
    }

    if ($NumCores -le 0) {
        $first = $scenarioResults | Where-Object { $_.num_cores } | Select-Object -First 1
        $NumCores = if ($first) { [int]$first.num_cores } else { [Environment]::ProcessorCount }
    }

    $hostName = ($scenarioResults | Where-Object { $_.host } | Select-Object -First 1).host
    if (-not $hostName) { $hostName = $env:COMPUTERNAME }

    $sensorProcessNames = @("minionhost", "ActiveConsole", "CrsSvc", "PylumLoader", "AmSvc", "WscIfSvc", "ExecutionPreventionSvc", "CrAmTray", "Nnx", "CrDrvCtrl")

    $sb = [System.Text.StringBuilder]::new()
    $genTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    [void]$sb.AppendLine(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cybereason Sensor Performance Report</title>
<style>
$($script:SharedCss)
</style>
</head>
<body>
<h1>Cybereason Sensor Performance Report</h1>
<p><strong>Generated:</strong> $genTime &nbsp;|&nbsp; <strong>Host:</strong> $hostName &nbsp;|&nbsp; <strong>Cores:</strong> $NumCores</p>
"@)

    # ── Test Info ──
    $firstStart = ($scenarioResults | Where-Object { $_.start_time } | Sort-Object { [datetime]$_.start_time } | Select-Object -First 1).start_time
    $lastEnd = ($scenarioResults | Where-Object { $_.end_time } | Sort-Object { [datetime]$_.end_time } -Descending | Select-Object -First 1).end_time
    $totalDurMin = if ($firstStart -and $lastEnd) { [math]::Round(([datetime]$lastEnd - [datetime]$firstStart).TotalMinutes, 1) } else { "?" }

    [void]$sb.AppendLine("<h2>Test Information</h2>")
    [void]$sb.AppendLine("<table>")
    [void]$sb.AppendLine("<tr><th>Property</th><th>Value</th></tr>")
    [void]$sb.AppendLine("<tr><td>Host</td><td>$hostName ($NumCores cores)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Scenarios run</td><td>$($scenarioResults.Count)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Test window</td><td>$firstStart &rarr; $lastEnd ($totalDurMin min)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Data source</td><td>Inline process metrics (Windows Performance Counters, 5s sampling)</td></tr>")
    [void]$sb.AppendLine("</table>")

    # ── Scenario Descriptions ──
    $scenarioNames = @($scenarioResults | ForEach-Object { $_.scenario } | Where-Object { $_ })
    if ($script:ScenarioDescriptions -and $scenarioNames.Count -gt 0) {
        [void]$sb.AppendLine("<h3>Scenarios</h3>")
        [void]$sb.AppendLine("<table><tr><th>#</th><th>Scenario</th><th>Description</th><th>Duration</th></tr>")
        $scIdx = 1
        foreach ($sr in $scenarioResults) {
            $scName = $sr.scenario
            if (-not $scName) { continue }
            $scDesc = if ($script:ScenarioDescriptions[$scName]) { $script:ScenarioDescriptions[$scName] } else { "-" }
            $durStr = if ($sr.duration_seconds) { "$([math]::Round($sr.duration_seconds, 0))s" } else { "-" }
            [void]$sb.AppendLine("<tr><td>$scIdx</td><td><code>$scName</code></td><td>$scDesc</td><td class=`"numeric`">$durStr</td></tr>")
            $scIdx++
        }
        [void]$sb.AppendLine("</table>")
    }

    [void]$sb.AppendLine(@"
<div class="callout">
<strong>CPU% Definition:</strong> All per-process CPU values are calculated from Windows <code>% Processor Time</code> deltas divided by the number of CPU cores ($NumCores). This normalizes to a 0&ndash;100% scale representing percentage of total system capacity. Sensor CPU is the sum across all sensor processes.
</div>
"@)

    # ── System CPU by scenario ──
    $hasSystemCpu = @($scenarioResults | Where-Object { $null -ne $_.system_avg_cpu_percent }).Count -gt 0
    if ($hasSystemCpu) {
        [void]$sb.AppendLine("<h2>System CPU by Scenario</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> Total system CPU utilization (all processes) during each scenario. Sourced from Windows <code>Processor(_Total)\% Processor Time</code> counter.</div>
"@)
        [void]$sb.AppendLine("<table><tr><th>Scenario</th><th>Avg CPU%</th><th>Peak CPU%</th><th>Sensor Avg CPU%</th></tr>")
        foreach ($sr in $scenarioResults) {
            if ($null -eq $sr.system_avg_cpu_percent) { continue }
            $avgVal = [math]::Round($sr.system_avg_cpu_percent, 1)
            $peakVal = if ($sr.system_peak_cpu_percent) { [math]::Round($sr.system_peak_cpu_percent, 1) } else { "-" }
            $sensorAvg = if ($sr.total_sensor_avg_cpu_percent) { "$([math]::Round($sr.total_sensor_avg_cpu_percent, 1))%" } else { "-" }
            $avgColor = Get-CpuColor $avgVal 30 70
            $peakColor = if ($peakVal -ne "-") { Get-CpuColor $peakVal 50 85 } else { "#95a5a6" }
            [void]$sb.AppendLine("<tr><td><code>$($sr.scenario)</code></td><td class=`"numeric`" style=`"background-color: $avgColor; color: white;`">$avgVal%</td><td class=`"numeric`" style=`"background-color: $peakColor; color: white;`">$peakVal%</td><td class=`"numeric`">$sensorAvg</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    }

    # ── Sensor Process CPU ──
    $scenariosWithMetrics = @($scenarioResults | Where-Object { $_.process_metrics })
    if ($scenariosWithMetrics.Count -gt 0) {
        [void]$sb.AppendLine("<h2>Sensor Process CPU - Average by Scenario</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> Per-process average CPU% for each sensor process across scenarios. CPU is normalized by $NumCores cores (0-100% scale = fraction of total system capacity).</div>
"@)

        $allSensorProcsPresent = @{}
        foreach ($sr in $scenariosWithMetrics) {
            $pm = $sr.process_metrics
            if ($pm -is [PSCustomObject]) {
                foreach ($prop in $pm.PSObject.Properties) {
                    if ($sensorProcessNames -contains $prop.Name) { $allSensorProcsPresent[$prop.Name] = $true }
                }
            } elseif ($pm -is [hashtable]) {
                foreach ($key in $pm.Keys) {
                    if ($sensorProcessNames -contains $key) { $allSensorProcsPresent[$key] = $true }
                }
            }
        }
        $sensorProcsSorted = @($sensorProcessNames | Where-Object { $allSensorProcsPresent.ContainsKey($_) })

        if ($sensorProcsSorted.Count -gt 0) {
            [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
            foreach ($pn in $sensorProcsSorted) { [void]$sb.AppendLine("<th>$pn</th>") }
            [void]$sb.AppendLine("<th><strong>Total Sensor</strong></th></tr>")

            foreach ($sr in $scenariosWithMetrics) {
                [void]$sb.AppendLine("<tr><td><code>$($sr.scenario)</code></td>")
                $pm = $sr.process_metrics
                $rowTotal = 0.0
                foreach ($pn in $sensorProcsSorted) {
                    $procData = $null
                    if ($pm -is [PSCustomObject] -and $pm.PSObject.Properties[$pn]) {
                        $procData = $pm.$pn
                    } elseif ($pm -is [hashtable] -and $pm.ContainsKey($pn)) {
                        $procData = $pm[$pn]
                    }
                    if ($procData) {
                        $val = [math]::Round([double]$procData.avg_cpu_percent, 1)
                        $rowTotal += $val
                        $color = Get-CpuColor $val 5 15
                        [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $color; color: white;`">$val%</td>")
                    } else {
                        [void]$sb.AppendLine("<td class=`"numeric`">0.0%</td>")
                    }
                }
                $totalColor = Get-CpuColor $rowTotal 10 25
                [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $totalColor; color: white; font-weight: bold;`">$([math]::Round($rowTotal, 1))%</td></tr>")
            }
            [void]$sb.AppendLine("</table>")
        }

        # ── Sensor Process CPU - Peak by Scenario ──
        [void]$sb.AppendLine("<h2>Sensor Process CPU - Peak by Scenario</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> The highest instantaneous CPU spike for each sensor process during each scenario. Captures worst-case bursts that averages smooth out.</div>
"@)

        if ($sensorProcsSorted.Count -gt 0) {
            [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
            foreach ($pn in $sensorProcsSorted) { [void]$sb.AppendLine("<th>$pn</th>") }
            [void]$sb.AppendLine("</tr>")

            foreach ($sr in $scenariosWithMetrics) {
                [void]$sb.AppendLine("<tr><td><code>$($sr.scenario)</code></td>")
                $pm = $sr.process_metrics
                foreach ($pn in $sensorProcsSorted) {
                    $procData = $null
                    if ($pm -is [PSCustomObject] -and $pm.PSObject.Properties[$pn]) {
                        $procData = $pm.$pn
                    } elseif ($pm -is [hashtable] -and $pm.ContainsKey($pn)) {
                        $procData = $pm[$pn]
                    }
                    if ($procData) {
                        $val = [math]::Round([double]$procData.peak_cpu_percent, 1)
                        $color = Get-CpuColor $val 10 30
                        [void]$sb.AppendLine("<td class=`"numeric`" style=`"background-color: $color; color: white;`">$val%</td>")
                    } else {
                        [void]$sb.AppendLine("<td class=`"numeric`">0.0%</td>")
                    }
                }
                [void]$sb.AppendLine("</tr>")
            }
            [void]$sb.AppendLine("</table>")
        }

        # ── Sensor Process Memory - Average ──
        [void]$sb.AppendLine("<h2>Sensor Process Memory (Working Set)</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> Average and peak working set (physical memory) in MB for each sensor process, measured every 5 seconds during each scenario.</div>
"@)

        if ($sensorProcsSorted.Count -gt 0) {
            [void]$sb.AppendLine("<table><tr><th rowspan=`"2`">Scenario</th>")
            foreach ($pn in $sensorProcsSorted) { [void]$sb.AppendLine("<th colspan=`"2`">$pn</th>") }
            [void]$sb.AppendLine("<th colspan=`"2`"><strong>Total</strong></th></tr>")
            [void]$sb.AppendLine("<tr>")
            foreach ($pn in $sensorProcsSorted) { [void]$sb.AppendLine("<th>Avg</th><th>Peak</th>") }
            [void]$sb.AppendLine("<th>Avg</th><th>Peak</th></tr>")

            foreach ($sr in $scenariosWithMetrics) {
                [void]$sb.AppendLine("<tr><td><code>$($sr.scenario)</code></td>")
                $pm = $sr.process_metrics
                $totalAvg = 0.0; $totalPeak = 0.0
                foreach ($pn in $sensorProcsSorted) {
                    $procData = $null
                    if ($pm -is [PSCustomObject] -and $pm.PSObject.Properties[$pn]) {
                        $procData = $pm.$pn
                    } elseif ($pm -is [hashtable] -and $pm.ContainsKey($pn)) {
                        $procData = $pm[$pn]
                    }
                    if ($procData) {
                        $avgMb = [math]::Round([double]$procData.avg_memory_mb, 1)
                        $peakMb = [math]::Round([double]$procData.peak_memory_mb, 1)
                        $totalAvg += $avgMb; $totalPeak += $peakMb
                        $avgColor = Get-ProcMemColor $avgMb
                        $peakColor = Get-ProcMemColor $peakMb
                        [void]$sb.AppendLine("<td class=`"numeric`" style=`"color: $avgColor;`">$avgMb</td><td class=`"numeric`" style=`"color: $peakColor;`">$peakMb</td>")
                    } else {
                        [void]$sb.AppendLine("<td class=`"numeric`">-</td><td class=`"numeric`">-</td>")
                    }
                }
                $totalAvgColor = Get-MemColor $totalAvg
                $totalPeakColor = Get-MemColor $totalPeak
                [void]$sb.AppendLine("<td class=`"numeric`" style=`"color: $totalAvgColor; font-weight: bold;`">$([math]::Round($totalAvg, 1))</td><td class=`"numeric`" style=`"color: $totalPeakColor; font-weight: bold;`">$([math]::Round($totalPeak, 1))</td>")
                [void]$sb.AppendLine("</tr>")
            }
            [void]$sb.AppendLine("</table>")
        }
        # ── Total System Memory Usage ──
        $hasMemData = @($scenarioResults | Where-Object { $null -ne $_.system_total_memory_mb -and $null -ne $_.system_used_memory_avg_mb }).Count -gt 0
        if ($hasMemData) {
            [void]$sb.AppendLine("<h2>Total System Memory Usage (All Processes + OS)</h2>")
            [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> Total physical RAM consumption across the entire system (OS + all processes) during each scenario. Sourced from Windows <code>Memory\Available MBytes</code> counter.</div>
"@)
            $firstMem = ($scenarioResults | Where-Object { $_.system_total_memory_mb } | Select-Object -First 1)
            $totalMemMb = if ($firstMem) { [int]$firstMem.system_total_memory_mb } else { 0 }
            [void]$sb.AppendLine("<table><tr><th>Scenario</th><th>Total RAM (MB)</th><th>Used Avg (MB)</th><th>Used Peak (MB)</th><th>Usage %</th></tr>")
            foreach ($sr in $scenarioResults) {
                if ($null -eq $sr.system_used_memory_avg_mb) { continue }
                $usedAvg = [math]::Round([double]$sr.system_used_memory_avg_mb, 0)
                $usedPeak = if ($sr.system_used_memory_peak_mb) { [math]::Round([double]$sr.system_used_memory_peak_mb, 0) } else { "-" }
                $pct = if ($totalMemMb -gt 0) { [math]::Round($usedAvg / $totalMemMb * 100, 1) } else { 0 }
                $memColor = Get-SysMemColor $usedAvg
                [void]$sb.AppendLine("<tr><td><code>$($sr.scenario)</code></td><td class=`"numeric`">$totalMemMb</td><td class=`"numeric`" style=`"color: $memColor; font-weight: bold;`">$usedAvg</td><td class=`"numeric`">$usedPeak</td><td class=`"numeric`">$pct%</td></tr>")
            }
            [void]$sb.AppendLine("</table>")
        }

        # ── Disk I/O (Write KB/s) ──
        $hasDiskData = @($scenarioResults | Where-Object { $null -ne $_.disk_write_avg_kbps }).Count -gt 0
        if ($hasDiskData) {
            [void]$sb.AppendLine("<h2>Disk I/O (Write KB/s)</h2>")
            [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> Disk write throughput during each scenario. Sourced from Windows <code>PhysicalDisk(_Total)\Disk Write Bytes/sec</code> counter.</div>
"@)
            [void]$sb.AppendLine("<table><tr><th>Scenario</th><th>Avg Write (KB/s)</th><th>Peak Write (KB/s)</th></tr>")
            foreach ($sr in $scenarioResults) {
                if ($null -eq $sr.disk_write_avg_kbps) { continue }
                $avgW = [math]::Round([double]$sr.disk_write_avg_kbps, 1)
                $peakW = if ($sr.disk_write_peak_kbps) { [math]::Round([double]$sr.disk_write_peak_kbps, 1) } else { "-" }
                $wColor = if ($avgW -ge 50000) { "#e74c3c" } elseif ($avgW -ge 10000) { "#f39c12" } else { "#27ae60" }
                [void]$sb.AppendLine("<tr><td><code>$($sr.scenario)</code></td><td class=`"numeric`" style=`"color: $wColor; font-weight: bold;`">$($avgW.ToString('N1'))</td><td class=`"numeric`">$($peakW.ToString('N1'))</td></tr>")
            }
            [void]$sb.AppendLine("</table>")
        }

        # ── Sensor Process Uptime & DB Size ──
        $hasUptimeOrDb = @($scenarioResults | Where-Object { $_.sensor_db_size_mb -or ($_.process_metrics -and (
            ($_.process_metrics -is [PSCustomObject] -and ($_.process_metrics.PSObject.Properties | Where-Object { $_.Value.uptime_minutes -ge 0 })) -or
            ($_.process_metrics -is [hashtable] -and ($_.process_metrics.Values | Where-Object { $_.uptime_minutes -ge 0 }))
        )) }).Count -gt 0
        if ($hasUptimeOrDb) {
            [void]$sb.AppendLine("<h2>Sensor Process Uptime &amp; DB Size</h2>")
            [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> Process uptime (how long main sensor processes have been running) and correlation DB size at each scenario. Process restarts during a scenario indicate stability issues.</div>
"@)
            $mainProcs = @("minionhost", "CrsSvc", "ActiveConsole")
            [void]$sb.AppendLine("<table><tr><th>Scenario</th>")
            foreach ($mp in $mainProcs) { [void]$sb.AppendLine("<th>$mp Uptime</th>") }
            [void]$sb.AppendLine("<th>DB Size (MB)</th></tr>")
            foreach ($sr in $scenarioResults) {
                $pm = $sr.process_metrics
                [void]$sb.AppendLine("<tr><td><code>$($sr.scenario)</code></td>")
                foreach ($mp in $mainProcs) {
                    $procData = $null
                    if ($pm -is [PSCustomObject] -and $pm.PSObject.Properties[$mp]) { $procData = $pm.$mp }
                    elseif ($pm -is [hashtable] -and $pm.ContainsKey($mp)) { $procData = $pm[$mp] }
                    if ($procData -and $procData.uptime_minutes -ge 0) {
                        $uMin = [math]::Round([double]$procData.uptime_minutes, 0)
                        $restarts = if ($procData.restarts -gt 0) { " <span style=`"color:#e74c3c;`">($($procData.restarts) restart$(if($procData.restarts -gt 1){'s'}))</span>" } else { "" }
                        if ($uMin -ge 60) {
                            $hrs = [math]::Floor($uMin / 60); $mins = $uMin % 60
                            [void]$sb.AppendLine("<td class=`"numeric`">${hrs}h ${mins}m$restarts</td>")
                        } else {
                            [void]$sb.AppendLine("<td class=`"numeric`">${uMin}m$restarts</td>")
                        }
                    } else {
                        [void]$sb.AppendLine("<td class=`"numeric`">-</td>")
                    }
                }
                $dbSize = if ($sr.sensor_db_size_mb) { "$([math]::Round([double]$sr.sensor_db_size_mb, 1))" } else { "-" }
                [void]$sb.AppendLine("<td class=`"numeric`">$dbSize</td></tr>")
            }
            [void]$sb.AppendLine("</table>")
        }

        # ── Process CPU/Memory Impact by Scenario (combined table) ──
        [void]$sb.AppendLine("<h2>Process CPU/Memory Impact by Scenario</h2>")
        [void]$sb.AppendLine(@"
<div class="callout"><strong>What this shows:</strong> Combined view of total sensor CPU% and memory impact per scenario, highlighting the scenarios with highest resource consumption.</div>
"@)
        [void]$sb.AppendLine("<table><tr><th>Scenario</th><th>System CPU Avg%</th><th>Sensor CPU Avg%</th><th>Sensor CPU Peak%</th><th>Sensor Mem Avg (MB)</th><th>Sensor Mem Peak (MB)</th></tr>")
        foreach ($sr in $scenariosWithMetrics) {
            $sysCpuAvg = if ($sr.system_avg_cpu_percent) { "$([math]::Round([double]$sr.system_avg_cpu_percent, 1))%" } else { "-" }
            $sensorCpuAvg = if ($sr.total_sensor_avg_cpu_percent) { "$([math]::Round([double]$sr.total_sensor_avg_cpu_percent, 1))%" } else { "-" }
            $pm = $sr.process_metrics
            $totalPeakCpu = 0.0; $totalAvgMem = 0.0; $totalPeakMem = 0.0
            foreach ($pn in $sensorProcessNames) {
                $procData = $null
                if ($pm -is [PSCustomObject] -and $pm.PSObject.Properties[$pn]) { $procData = $pm.$pn }
                elseif ($pm -is [hashtable] -and $pm.ContainsKey($pn)) { $procData = $pm[$pn] }
                if ($procData) {
                    $totalPeakCpu += [double]$procData.peak_cpu_percent
                    $totalAvgMem += [double]$procData.avg_memory_mb
                    $totalPeakMem += [double]$procData.peak_memory_mb
                }
            }
            $cpuColor = Get-CpuColor ([math]::Round($totalPeakCpu, 1)) 15 40
            [void]$sb.AppendLine("<tr><td><code>$($sr.scenario)</code></td><td class=`"numeric`">$sysCpuAvg</td><td class=`"numeric`">$sensorCpuAvg</td><td class=`"numeric`" style=`"background-color: $cpuColor; color: white;`">$([math]::Round($totalPeakCpu, 1))%</td><td class=`"numeric`">$([math]::Round($totalAvgMem, 1))</td><td class=`"numeric`">$([math]::Round($totalPeakMem, 1))</td></tr>")
        }
        [void]$sb.AppendLine("</table>")
    } else {
        [void]$sb.AppendLine(@"
<div class="summary-box summary-warn"><strong>No process metrics available.</strong> Run scenarios with <code>-CollectMetrics</code> to enable inline process CPU and memory sampling.</div>
"@)
    }

    # ── Executive Summary (auto-generated findings) ──
    $findings = [System.Collections.Generic.List[string]]::new()
    $overallSeverity = "ok"

    foreach ($sr in $scenarioResults) {
        if ($sr.total_sensor_avg_cpu_percent -and [double]$sr.total_sensor_avg_cpu_percent -ge 15) {
            $findings.Add("Sensor CPU averaged <strong>$([math]::Round([double]$sr.total_sensor_avg_cpu_percent, 1))%</strong> during <code>$($sr.scenario)</code> (threshold: 15%)")
            $overallSeverity = "crit"
        } elseif ($sr.total_sensor_avg_cpu_percent -and [double]$sr.total_sensor_avg_cpu_percent -ge 5) {
            $findings.Add("Sensor CPU averaged <strong>$([math]::Round([double]$sr.total_sensor_avg_cpu_percent, 1))%</strong> during <code>$($sr.scenario)</code> (threshold: 5%)")
            if ($overallSeverity -ne "crit") { $overallSeverity = "warn" }
        }
    }

    $scenariosWithMetrics2 = @($scenarioResults | Where-Object { $_.process_metrics })
    foreach ($sr in $scenariosWithMetrics2) {
        $pm = $sr.process_metrics
        $totalMem = 0.0
        foreach ($pn in $sensorProcessNames) {
            $procData = $null
            if ($pm -is [PSCustomObject] -and $pm.PSObject.Properties[$pn]) { $procData = $pm.$pn }
            elseif ($pm -is [hashtable] -and $pm.ContainsKey($pn)) { $procData = $pm[$pn] }
            if ($procData) { $totalMem += [double]$procData.peak_memory_mb }
        }
        if ($totalMem -ge 500) {
            $findings.Add("Sensor peak memory reached <strong>$([math]::Round($totalMem, 0)) MB</strong> during <code>$($sr.scenario)</code> (threshold: 500 MB)")
            $overallSeverity = "crit"
        } elseif ($totalMem -ge 350) {
            $findings.Add("Sensor peak memory reached <strong>$([math]::Round($totalMem, 0)) MB</strong> during <code>$($sr.scenario)</code> (threshold: 350 MB)")
            if ($overallSeverity -ne "crit") { $overallSeverity = "warn" }
        }
    }

    foreach ($sr in $scenarioResults) {
        if ($sr.disk_write_peak_kbps -and [double]$sr.disk_write_peak_kbps -ge 100000) {
            $findings.Add("Disk write peaked at <strong>$([math]::Round([double]$sr.disk_write_peak_kbps / 1024, 1)) MB/s</strong> during <code>$($sr.scenario)</code>")
            if ($overallSeverity -ne "crit") { $overallSeverity = "warn" }
        }
    }

    $summaryClass = switch ($overallSeverity) { "crit" { "summary-crit" } "warn" { "summary-warn" } default { "summary-ok" } }
    $summaryIcon = switch ($overallSeverity) { "crit" { "FAIL" } "warn" { "WARNING" } default { "PASS" } }
    $summaryText = switch ($overallSeverity) {
        "crit" { "One or more KPI thresholds were exceeded. Review the findings below." }
        "warn" { "Some metrics are approaching KPI thresholds. Review the findings below." }
        default { "All sensor performance metrics are within acceptable KPI thresholds." }
    }

    $execSummaryHtml = @"
<h2>Executive Summary</h2>
<div class="summary-box $summaryClass">
<strong>Overall Assessment: $summaryIcon</strong><br/>
$summaryText
</div>
"@
    if ($findings.Count -gt 0) {
        $execSummaryHtml += "<h3>Key Findings</h3><ul>"
        foreach ($f in $findings) { $execSummaryHtml += "<li class=`"finding`">$f</li>" }
        $execSummaryHtml += "</ul>"
    }

    # ── Bottom Line & Conclusions ──
    $kpiTable = @"
<h2>Bottom Line</h2>
<div class="callout"><strong>KPI Assessment:</strong> Comparing measured sensor performance against release-gate thresholds.</div>
<table>
<tr><th>Metric</th><th>Threshold (Idle)</th><th>Threshold (Load)</th><th>Measured (Worst)</th><th>Status</th></tr>
"@
    $worstIdleCpu = 0.0; $worstLoadCpu = 0.0; $worstMem = 0.0
    foreach ($sr in $scenarioResults) {
        if (-not $sr.total_sensor_avg_cpu_percent) { continue }
        $cpu = [double]$sr.total_sensor_avg_cpu_percent
        if ($sr.scenario -eq "idle_baseline") { if ($cpu -gt $worstIdleCpu) { $worstIdleCpu = $cpu } }
        else { if ($cpu -gt $worstLoadCpu) { $worstLoadCpu = $cpu } }
    }
    foreach ($sr in $scenariosWithMetrics2) {
        $pm = $sr.process_metrics
        $totalMem = 0.0
        foreach ($pn in $sensorProcessNames) {
            $procData = $null
            if ($pm -is [PSCustomObject] -and $pm.PSObject.Properties[$pn]) { $procData = $pm.$pn }
            elseif ($pm -is [hashtable] -and $pm.ContainsKey($pn)) { $procData = $pm[$pn] }
            if ($procData) { $totalMem += [double]$procData.peak_memory_mb }
        }
        if ($totalMem -gt $worstMem) { $worstMem = $totalMem }
    }

    $cpuIdleStatus = if ($worstIdleCpu -lt 2) { "<span style=`"color:#27ae60; font-weight:bold;`">PASS</span>" } elseif ($worstIdleCpu -lt 5) { "<span style=`"color:#f39c12; font-weight:bold;`">WARN</span>" } else { "<span style=`"color:#e74c3c; font-weight:bold;`">FAIL</span>" }
    $cpuLoadStatus = if ($worstLoadCpu -lt 15) { "<span style=`"color:#27ae60; font-weight:bold;`">PASS</span>" } elseif ($worstLoadCpu -lt 25) { "<span style=`"color:#f39c12; font-weight:bold;`">WARN</span>" } else { "<span style=`"color:#e74c3c; font-weight:bold;`">FAIL</span>" }
    $memStatus = if ($worstMem -lt 350) { "<span style=`"color:#27ae60; font-weight:bold;`">PASS</span>" } elseif ($worstMem -lt 500) { "<span style=`"color:#f39c12; font-weight:bold;`">WARN</span>" } else { "<span style=`"color:#e74c3c; font-weight:bold;`">FAIL</span>" }

    $kpiTable += "<tr><td>CPU (Idle)</td><td>&lt; 2% avg</td><td>N/A</td><td class=`"numeric`">$([math]::Round($worstIdleCpu, 1))%</td><td>$cpuIdleStatus</td></tr>"
    $kpiTable += "<tr><td>CPU (Under Load)</td><td>N/A</td><td>&lt; 15% sustained</td><td class=`"numeric`">$([math]::Round($worstLoadCpu, 1))%</td><td>$cpuLoadStatus</td></tr>"
    $kpiTable += "<tr><td>Memory (RSS Peak)</td><td>&lt; 350 MB</td><td>&lt; 500 MB</td><td class=`"numeric`">$([math]::Round($worstMem, 0)) MB</td><td>$memStatus</td></tr>"
    $kpiTable += "</table>"

    $conclusionsHtml = @"
<h2>Conclusions</h2>
<div class="bottom-line">
<p><strong>Test completed on $hostName ($NumCores cores).</strong></p>
<ul>
<li><strong>CPU Impact:</strong> Sensor averaged <strong>$([math]::Round($worstIdleCpu, 1))%</strong> at idle and peaked at <strong>$([math]::Round($worstLoadCpu, 1))%</strong> under load across $($scenarioResults.Count) scenarios.</li>
<li><strong>Memory Impact:</strong> Peak total sensor working set was <strong>$([math]::Round($worstMem, 0)) MB</strong>.</li>
"@
    $worstDiskWrite = 0.0
    foreach ($sr in $scenarioResults) {
        if ($sr.disk_write_peak_kbps -and [double]$sr.disk_write_peak_kbps -gt $worstDiskWrite) { $worstDiskWrite = [double]$sr.disk_write_peak_kbps }
    }
    if ($worstDiskWrite -gt 0) {
        $conclusionsHtml += "<li><strong>Disk I/O:</strong> Peak disk write rate was <strong>$([math]::Round($worstDiskWrite / 1024, 1)) MB/s</strong>.</li>"
    }
    $conclusionsHtml += @"
</ul>
<p><em>Report generated: $genTime</em></p>
</div>
"@

    # Insert Executive Summary right after the test info + scenario descriptions
    $currentHtml = $sb.ToString()
    $cpuDefIdx = $currentHtml.IndexOf('<div class="callout">')
    if ($cpuDefIdx -gt 0) {
        $sb.Clear()
        [void]$sb.Append($currentHtml.Substring(0, $cpuDefIdx))
        [void]$sb.AppendLine($execSummaryHtml)
        [void]$sb.Append($currentHtml.Substring($cpuDefIdx))
    }

    [void]$sb.AppendLine($kpiTable)
    [void]$sb.AppendLine($conclusionsHtml)
    [void]$sb.AppendLine("</body></html>")
    return $sb.ToString()
}

# ── Build the separate ETL report ──

function Build-EtlReport {
    param($EtlData, [switch]$UseSymbols)

    $sb = [System.Text.StringBuilder]::new()
    $genTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [void]$sb.AppendLine(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ETL Trace Analysis Report</title>
<style>
$($script:SharedCss)
</style>
</head>
<body>
<h1>ETL Trace Analysis (CPU Hotspots)</h1>
<p><strong>Generated:</strong> $genTime</p>
<p>ETL profiling analysis for the heaviest scenarios. Shows which processes and functions consumed the most CPU during the trace.</p>
"@)

    if (-not $EtlData -or -not $EtlData.traces) {
        [void]$sb.AppendLine("<p>No ETL trace data available.</p>")
    } else {
        $validTraces = @($EtlData.traces | Where-Object { -not $_.error -and $_.topProcesses })
        $globalTotalWeightMs = ($validTraces | Measure-Object -Property totalWeightMs -Sum).Sum
        $globalTotalSamples = ($validTraces | ForEach-Object { if ($_.sampleCount) { $_.sampleCount } else { 0 } } | Measure-Object -Sum).Sum
        $traceCount = $validTraces.Count
        $globalWeightSec = [math]::Round($globalTotalWeightMs / 1000, 0)
        $globalWeightMin = [math]::Round($globalTotalWeightMs / 1000 / 60, 1)

        $scenarioNames = @($validTraces | ForEach-Object {
            $raw = $_.scenario
            $matched = $script:ScenarioDescriptions.Keys | Where-Object { $raw -eq $_ -or $raw.StartsWith("${_}_") } |
                Sort-Object { $_.Length } -Descending | Select-Object -First 1
            if ($matched) { $matched } else { $raw }
        })
        $scenarioNames = @($scenarioNames | Select-Object -Unique)

        $hostMatch = "Unknown"
        $firstTrace = $validTraces[0]
        if ($firstTrace.scenario -match '(TEST-PERF-S\d+)') {
            $hostMatch = $Matches[1]
        } elseif ($firstTrace.traceFile -match '(TEST-PERF-S\d+)') {
            $hostMatch = $Matches[1]
        } else {
            $rawScen = $firstTrace.scenario
            $matchedKey = $script:ScenarioDescriptions.Keys | Where-Object { $rawScen -eq $_ -or $rawScen.StartsWith("${_}_") } |
                Sort-Object { $_.Length } -Descending | Select-Object -First 1
            if ($matchedKey -and $rawScen.Length -gt $matchedKey.Length) {
                $hostMatch = $rawScen.Substring($matchedKey.Length + 1)
            }
        }
        $etlRoleMap = @{ "TEST-PERF-S1" = "No Sensor (Baseline)"; "TEST-PERF-S2" = "V26.1 + Phoenix"; "TEST-PERF-S3" = "V26.1 + Legacy"; "TEST-PERF-S4" = "V24.1 + Legacy" }
        $traceRole = if ($etlRoleMap[$hostMatch]) { "$hostMatch ($($etlRoleMap[$hostMatch]))" } else { $hostMatch }

        [void]$sb.AppendLine("<h2>Trace Summary</h2>")
        [void]$sb.AppendLine("<table>")
        [void]$sb.AppendLine("<tr><th>Property</th><th>Value</th></tr>")
        [void]$sb.AppendLine("<tr><td>Host</td><td>$traceRole</td></tr>")
        [void]$sb.AppendLine("<tr><td>Scenarios</td><td>$($scenarioNames -join ', ') ($traceCount total)</td></tr>")
        [void]$sb.AppendLine("<tr><td>Total CPU Samples</td><td>$($globalTotalSamples.ToString('N0'))</td></tr>")
        [void]$sb.AppendLine("<tr><td>Total CPU Weight</td><td>$($globalWeightSec.ToString('N0'))s ($globalWeightMin min across all cores)</td></tr>")
        [void]$sb.AppendLine("</table>")

        if ($script:ScenarioDescriptions -and $scenarioNames.Count -gt 0) {
            [void]$sb.AppendLine("<h3>Scenarios Profiled</h3>")
            [void]$sb.AppendLine("<table><tr><th>#</th><th>Scenario</th><th>Description</th></tr>")
            $scIdx = 1
            foreach ($scName in $scenarioNames) {
                $scDesc = if ($script:ScenarioDescriptions[$scName]) { $script:ScenarioDescriptions[$scName] } else { "-" }
                [void]$sb.AppendLine("<tr><td>$scIdx</td><td><code>$scName</code></td><td>$scDesc</td></tr>")
                $scIdx++
            }
            [void]$sb.AppendLine("</table>")
        }

        [void]$sb.AppendLine("<div class=`"callout`"><strong>How to read this report:</strong> CPU samples from <strong>$traceCount scenarios</strong> are aggregated into unified tables. Each percentage represents the fraction of <em>total system CPU capacity</em> across all cores and all traces combined. On a 2-core machine, 100% = both cores fully utilized for the entire combined duration. This gives a holistic view of CPU consumption across diverse workload types.</div>")

        $sensorProcessNames = @("minionhost", "ActiveConsole", "CrsSvc", "PylumLoader", "AmSvc", "WscIfSvc", "ExecutionPreventionSvc", "CrAmTray", "Nnx", "CrDrvCtrl")
        $globalProcesses = @{}

        foreach ($t in $validTraces) {
            foreach ($p in $t.topProcesses) {
                if ($globalProcesses.ContainsKey($p.process)) {
                    $globalProcesses[$p.process].weightMs += [double]$p.weightMs
                } else {
                    $globalProcesses[$p.process] = @{
                        process = $p.process
                        weightMs = [double]$p.weightMs
                        isSensor = $sensorProcessNames -contains $p.process
                    }
                }
            }
        }

        foreach ($key in @($globalProcesses.Keys)) {
            $globalProcesses[$key].percent = if ($globalTotalWeightMs -gt 0) { [math]::Round($globalProcesses[$key].weightMs / $globalTotalWeightMs * 100, 3) } else { 0 }
        }

        $sensorProcs = @($globalProcesses.Values | Where-Object { $_.isSensor } | Sort-Object { $_.weightMs } -Descending)
        $otherProcs = @($globalProcesses.Values | Where-Object { -not $_.isSensor } | Sort-Object { $_.weightMs } -Descending)

        if ($sensorProcs.Count -gt 0) {
            $totalSensorMs = ($sensorProcs | ForEach-Object { $_.weightMs } | Measure-Object -Sum).Sum
            $totalSensorPct = if ($globalTotalWeightMs -gt 0) { [math]::Round($totalSensorMs / $globalTotalWeightMs * 100, 2) } else { 0 }
            [void]$sb.AppendLine("<h2>Sensor Processes (Cybereason)</h2>")
            [void]$sb.AppendLine("<table><tr><th>Process</th><th>CPU time (ms)</th><th>% of Total CPU</th></tr>")
            foreach ($p in $sensorProcs) {
                [void]$sb.AppendLine("<tr><td><strong>$($p.process)</strong></td><td class=`"numeric`">$([math]::Round($p.weightMs, 1).ToString('N1'))</td><td class=`"numeric`">$($p.percent)%</td></tr>")
            }
            [void]$sb.AppendLine("<tr class=`"total-row`"><td><strong>Total Sensor CPU</strong></td><td class=`"numeric`">$([math]::Round($totalSensorMs, 1).ToString('N1'))</td><td class=`"numeric`">$totalSensorPct%</td></tr>")
            [void]$sb.AppendLine("</table>")
        }

        if ($otherProcs.Count -gt 0) {
            [void]$sb.AppendLine("<h2>Other System Processes</h2>")
            [void]$sb.AppendLine("<table><tr><th>Process</th><th>CPU time (ms)</th><th>% of Total CPU</th></tr>")
            foreach ($p in $otherProcs) {
                [void]$sb.AppendLine("<tr><td>$($p.process)</td><td class=`"numeric`">$([math]::Round($p.weightMs, 1).ToString('N1'))</td><td class=`"numeric`">$($p.percent)%</td></tr>")
            }
            [void]$sb.AppendLine("</table>")
        }

        $hasAnyFunctions = @($validTraces | Where-Object { $_.topFunctions -and $_.topFunctions.Count -gt 0 }).Count -gt 0
        if (($UseSymbols -or $hasAnyFunctions) -and $validTraces.Count -gt 0) {
            [void]$sb.AppendLine("<h2>Function-Level Hotspots</h2>")
            $sensorModules = @("minionhost", "ActiveConsole", "PylumLoader", "CrsSvc", "AmSvc", "WscIfSvc", "ExecutionPreventionSvc", "CrAmTray", "CrDrvCtrl", "Nnx")

            $globalFunctions = @{}

            foreach ($t in $validTraces) {
                if (-not $t.topFunctions) { continue }
                $rawSc = $t.scenario
                $traceScenario = $script:ScenarioDescriptions.Keys | Where-Object { $rawSc -eq $_ -or $rawSc.StartsWith("${_}_") } |
                    Sort-Object { $_.Length } -Descending | Select-Object -First 1
                if (-not $traceScenario) { $traceScenario = $rawSc }
                $filtered = @($t.topFunctions | Where-Object {
                    $sensorModules -contains $_.module -and
                    $_.function -notlike "boost::*" -and
                    $_.function -notlike "std::*" -and
                    $_.function -notlike "sqlite3*" -and
                    $_.function -notlike "nghttp2*" -and
                    $_.function -notlike "ossl_*" -and
                    $_.function -notlike "OPENSSL_*" -and
                    $_.function -notlike "operator new*" -and
                    $_.function -notlike "operator delete*" -and
                    $_.function -notlike "__crt_*" -and
                    $_.function -notlike "memcpy*" -and
                    $_.function -notlike "memset*" -and
                    $_.function -notlike "strlen*" -and
                    $_.function -notlike "malloc*" -and
                    $_.function -notlike "free*" -and
                    $_.function -notlike "vcruntime*" -and
                    $_.function -notlike "_guard_*" -and
                    $_.function -notlike "__guard_*" -and
                    $_.function -notlike "__security_*" -and
                    $_.function -notlike "ntdll!*" -and
                    $_.function -notlike "ntoskrnl!*" -and
                    $_.function -notlike "ucrtbase!*"
                })
                foreach ($f in $filtered) {
                    $key = "$($f.module)|$($f.function)"
                    if ($globalFunctions.ContainsKey($key)) {
                        $globalFunctions[$key].weightMs += [double]$f.weightMs
                        if ($globalFunctions[$key].scenarios -notcontains $traceScenario) {
                            $globalFunctions[$key].scenarios += $traceScenario
                        }
                    } else {
                        $globalFunctions[$key] = @{
                            module = $f.module
                            function = $f.function
                            weightMs = [double]$f.weightMs
                            scenarios = @($traceScenario)
                        }
                    }
                }
            }

            if ($globalFunctions.Count -gt 0) {
                $hasUnresolved = @($globalFunctions.Values | Where-Object { $_.function -match '^0x' }).Count -gt 0
                $hasResolved = @($globalFunctions.Values | Where-Object { $_.function -notmatch '^0x' }).Count -gt 0
                if ($hasUnresolved -and -not $hasResolved) {
                    [void]$sb.AppendLine('<div class="callout" style="border-left: 4px solid #f39c12;"><strong>Symbol Note:</strong> Function names could not be resolved because the PDB symbol files do not exactly match the installed sensor binaries (GUID mismatch). The addresses shown are memory offsets within each module. To resolve function names, obtain PDB files from the exact same build as the installed sensor.</div>')
                } else {
                    [void]$sb.AppendLine("<div class=`"callout`"><strong>What this shows:</strong> Top CPU-consuming functions within Cybereason sensor modules, resolved from PDB symbol files. Each function''s weight is the sum of its CPU samples across all scenarios. OS and third-party functions are excluded.</div>")
                }
                $sortedGlobal = $globalFunctions.Values | Sort-Object { $_.weightMs } -Descending
                [void]$sb.AppendLine("<table><tr><th>#</th><th>Module</th><th>Function</th><th>CPU time (ms)</th><th>% of Total CPU</th><th>Seen in</th></tr>")
                $rank = 1
                foreach ($f in $sortedGlobal) {
                    $pct = if ($globalTotalWeightMs -gt 0) { [math]::Round($f.weightMs / $globalTotalWeightMs * 100, 3) } else { 0 }
                    $seenLabel = $f.scenarios -join ", "
                    [void]$sb.AppendLine("<tr><td>$rank</td><td><strong>$($f.module)</strong></td><td><code>$($f.function)</code></td><td class=`"numeric`">$([math]::Round($f.weightMs, 1).ToString('N1'))</td><td class=`"numeric`">$pct%</td><td>$seenLabel</td></tr>")
                    $rank++
                }
                [void]$sb.AppendLine("</table>")
            }
        }
    }

    [void]$sb.AppendLine("</body></html>")
    return $sb.ToString()
}

# ── Convert HTML report to Confluence-pasteable format (inline all styles) ──

function Convert-ToConfluence {
    param([string]$Html)

    $out = $Html
    $out = $out -replace '<style>[\s\S]*?</style>', ''
    $out = $out -replace '<!DOCTYPE html>', ''
    $out = $out -replace '<html[^>]*>', ''
    $out = $out -replace '</html>', ''
    $out = $out -replace '<head>[\s\S]*?</head>', ''
    $out = $out -replace '</?body[^>]*>', ''

    $out = $out -replace 'class="[^"]*"', ''

    $tdBase = "border: 1px solid #bdc3c7; padding: 6px 10px;"
    $thBase = "border: 1px solid #bdc3c7; padding: 6px 10px; background: #ecf0f1; font-weight: 600;"

    $out = $out -replace '<table>', '<table style="border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 13px;">'

    $out = [regex]::Replace($out, '<th\b([^>]*)>', {
        param($m)
        $attrs = $m.Groups[1].Value
        if ($attrs -match 'style="([^"]*)"') {
            $existing = $Matches[1]
            $attrs = $attrs -replace 'style="[^"]*"', "style=`"$thBase $existing`""
        } else {
            $attrs = " style=`"$thBase`"" + $attrs
        }
        return "<th$attrs>"
    })

    $out = [regex]::Replace($out, '<td\b([^>]*)>', {
        param($m)
        $attrs = $m.Groups[1].Value
        if ($attrs -match 'style="([^"]*)"') {
            $existing = $Matches[1]
            $attrs = $attrs -replace 'style="[^"]*"', "style=`"$tdBase $existing`""
        } else {
            $attrs = " style=`"$tdBase`"" + $attrs
        }
        return "<td$attrs>"
    })

    $out = $out -replace '<h1([^>]*)>', '<h1$1 style="color: #2980b9; border-bottom: 2px solid #2980b9; padding-bottom: 8px;">'
    $out = $out -replace '<h2([^>]*)>', '<h2$1 style="color: #2980b9; border-left: 4px solid #2980b9; padding-left: 12px; margin-top: 28px;">'
    $out = $out -replace '<h3([^>]*)>', '<h3$1 style="color: #34495e; margin-top: 20px;">'

    return $out.Trim()
}

# ══════════════════════════════════════════════════
# MAIN EXECUTION
# ══════════════════════════════════════════════════

if (-not $OutputPath) {
    $OutputPath = Join-Path $toolsDir "perf-bottleneck-report-$(Get-Date -Format 'yyyyMMdd').html"
} else {
    if ([System.IO.Path]::GetExtension($OutputPath) -ne ".html") {
        $OutputPath = [System.IO.Path]::ChangeExtension($OutputPath, "html")
    }
}
if (-not $EtlOutputPath) {
    $EtlOutputPath = Join-Path (Split-Path $OutputPath -Parent) "perf-report-etl.html"
}

# ── Self-service mode: generate report from scenario JSONs, no InfluxDB needed ──
if ($ScenarioResultsDir) {
    if (-not (Test-Path $ScenarioResultsDir)) {
        throw "Scenario results directory not found: $ScenarioResultsDir"
    }
    Write-Host "Building self-service performance report from: $ScenarioResultsDir" -ForegroundColor Cyan
    $report = Build-SelfServiceReport -ResultsDir $ScenarioResultsDir -NumCores $NumCores | Out-String
    $report | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host "Performance report written to: $OutputPath" -ForegroundColor Green

    if (-not $SkipEtl) {
        $etlData = $null
        if ($EtlJsonPath -and (Test-Path $EtlJsonPath)) {
            Write-Host "Using ETL data from: $EtlJsonPath" -ForegroundColor Cyan
            $etlData = Get-Content $EtlJsonPath -Raw | ConvertFrom-Json
        } elseif (Test-Path $TraceDir) {
            $etlProject = Join-Path $scriptDir "etl-analyzer\EtlAnalyzer.csproj"
            if (Test-Path $etlProject) {
                Write-Host "Processing ETL traces..." -ForegroundColor Cyan
                $etlJson = Join-Path $env:TEMP "perf-etl-$(Get-Date -Format 'yyyyMMddHHmmss').json"
                $etlArgs = @("run", "--project", $etlProject, "--", $TraceDir)
                if ($UseSymbols) { $etlArgs += "--symbols" }
                if ($TraceLimit -gt 0) { $etlArgs += "--limit"; $etlArgs += $TraceLimit.ToString() }
                $ErrorActionPreferencePrev = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                $etlOutput = & dotnet @etlArgs 2>&1 | Out-String
                $ErrorActionPreference = $ErrorActionPreferencePrev
                $etlOutput | Out-File $etlJson -Encoding utf8
                try {
                    $etlJsonContent = Get-Content $etlJson -Raw
                    $jsonMatch = [regex]::Match($etlJsonContent, '\{\s*"traces"\s*:[\s\S]*\}')
                    if ($jsonMatch.Success) { $etlData = $jsonMatch.Value | ConvertFrom-Json }
                } catch { Write-Warning "ETL analyzer output could not be parsed: $_" }
                finally { if (Test-Path $etlJson) { Remove-Item $etlJson -Force -ErrorAction SilentlyContinue } }
            }
        }
        if ($etlData) {
            $etlReport = Build-EtlReport -EtlData $etlData -UseSymbols:$UseSymbols | Out-String
            $etlReport | Set-Content -Path $EtlOutputPath -Encoding UTF8
            Write-Host "ETL report written to: $EtlOutputPath" -ForegroundColor Green
        }
    }

    if ($GenerateConfluence) {
        Write-Host "Generating Confluence-compatible reports..." -ForegroundColor Cyan
        $confMainPath = [System.IO.Path]::ChangeExtension($OutputPath, "confluence.html")
        $confMain = Convert-ToConfluence $report
        $confMain | Set-Content -Path $confMainPath -Encoding UTF8
        Write-Host "Confluence report: $confMainPath" -ForegroundColor Green
        if ($etlData) {
            $confEtlPath = [System.IO.Path]::ChangeExtension($EtlOutputPath, "confluence.html")
            $confEtl = Convert-ToConfluence $etlReport
            $confEtl | Set-Content -Path $confEtlPath -Encoding UTF8
            Write-Host "Confluence ETL report: $confEtlPath" -ForegroundColor Green
        }
    }
    return
}

# ── Standard mode: InfluxDB + ETL ──

$influxJson = Join-Path $env:TEMP "perf-influx-$(Get-Date -Format 'yyyyMMddHHmmss').json"
$etlJson = Join-Path $env:TEMP "perf-etl-$(Get-Date -Format 'yyyyMMddHHmmss').json"

try {
    # --- Part 1: InfluxDB analysis ---
    $influxData = $null
    $influxScript = Join-Path $scriptDir "influx-analyze.ps1"
    if (-not (Test-Path $influxScript)) {
        throw "influx-analyze.ps1 not found at $influxScript"
    }

    if ($InfluxJsonPath -and (Test-Path $InfluxJsonPath)) {
        Write-Host "Using InfluxDB data from: $InfluxJsonPath" -ForegroundColor Cyan
        $influxData = Get-Content $InfluxJsonPath -Raw | ConvertFrom-Json
    } elseif ($Token -and -not $SkipInfluxDB) {
        Write-Host "Querying InfluxDB..." -ForegroundColor Cyan
        $influxParams = @{ Token = $Token; OutputPath = $influxJson; InfluxUrl = $InfluxUrl; TimeRange = $TimeRange }
        try {
            & $influxScript @influxParams 2>&1 | Out-Null
            if (Test-Path $influxJson) {
                $influxData = Get-Content $influxJson -Raw | ConvertFrom-Json
            }
        } catch {
            Write-Warning "InfluxDB analysis failed: $_"
        }
    } elseif ($SkipInfluxDB) {
        Write-Host "Skipping InfluxDB (-SkipInfluxDB specified)." -ForegroundColor Yellow
    } else {
        Write-Warning "Skipping InfluxDB (set `$env:INFLUXDB_TOKEN or pass -Token)."
    }

    # --- Part 2: ETL analysis ---
    $etlData = $null
    $etlProject = Join-Path $scriptDir "etl-analyzer\EtlAnalyzer.csproj"
    if ($EtlJsonPath -and (Test-Path $EtlJsonPath)) {
        Write-Host "Using ETL data from: $EtlJsonPath" -ForegroundColor Cyan
        $etlData = Get-Content $EtlJsonPath -Raw | ConvertFrom-Json
    } elseif ($SkipEtl) {
        Write-Host "Skipping ETL analysis (-SkipEtl specified)." -ForegroundColor Yellow
    } elseif (-not (Test-Path $etlProject)) {
        Write-Warning "EtlAnalyzer project not found at $etlProject. Skipping ETL."
    } elseif (-not (Test-Path $TraceDir)) {
        Write-Warning "Trace directory not found: $TraceDir"
    } else {
        $traceInfo = if ($TraceLimit -gt 0) { "first $TraceLimit traces" } else { "all traces (~30-60 min for ~14.5 GB)" }
        Write-Host "Processing ETL traces ($traceInfo)..." -ForegroundColor Cyan
        if ($UseSymbols) {
            $symPath = "srv*$env:LOCALAPPDATA\Symbols*\\172.25.1.155\symbols-releases;srv*$env:LOCALAPPDATA\Symbols*https://msdl.microsoft.com/download/symbols"
            if (-not $env:_NT_SYMBOL_PATH) { $env:_NT_SYMBOL_PATH = $symPath; Write-Host "  Using symbol path for readable function names" -ForegroundColor Gray }
        }
        $etlArgs = @("run", "--project", $etlProject, "--", $TraceDir)
        if ($UseSymbols) { $etlArgs += "--symbols" }
        if ($TraceLimit -gt 0) { $etlArgs += "--limit"; $etlArgs += $TraceLimit.ToString() }

        $ErrorActionPreferencePrev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $etlOutput = & dotnet @etlArgs 2>&1 | Out-String
        $ErrorActionPreference = $ErrorActionPreferencePrev
        $etlOutput | Out-File $etlJson -Encoding utf8
        $etlData = $null
        try {
            $etlJsonContent = Get-Content $etlJson -Raw
            $jsonMatch = [regex]::Match($etlJsonContent, '\{\s*"traces"\s*:[\s\S]*\}')
            if ($jsonMatch.Success) {
                $etlData = $jsonMatch.Value | ConvertFrom-Json
            }
        } catch {
            Write-Warning "ETL analyzer output could not be parsed: $_"
        }
    }

    # --- Part 3: Generate main report ---
    Write-Host "Generating main report..." -ForegroundColor Cyan
    $report = Build-Report -InfluxData $influxData -NumCores $NumCores | Out-String
    $report | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host "Main report written to: $OutputPath" -ForegroundColor Green

    # --- Part 4: Generate ETL report ---
    Write-Host "Generating ETL report..." -ForegroundColor Cyan
    $etlReport = Build-EtlReport -EtlData $etlData -UseSymbols:$UseSymbols | Out-String
    $etlReport | Set-Content -Path $EtlOutputPath -Encoding UTF8
    Write-Host "ETL report written to: $EtlOutputPath" -ForegroundColor Green

    # --- Part 5: Generate Confluence-compatible versions ---
    if ($GenerateConfluence) {
        Write-Host "Generating Confluence-compatible reports..." -ForegroundColor Cyan
        $confMainPath = [System.IO.Path]::ChangeExtension($OutputPath, "confluence.html")
        $confEtlPath = [System.IO.Path]::ChangeExtension($EtlOutputPath, "confluence.html")
        $confMain = Convert-ToConfluence $report
        $confMain | Set-Content -Path $confMainPath -Encoding UTF8
        Write-Host "Confluence main report: $confMainPath" -ForegroundColor Green
        $confEtl = Convert-ToConfluence $etlReport
        $confEtl | Set-Content -Path $confEtlPath -Encoding UTF8
        Write-Host "Confluence ETL report: $confEtlPath" -ForegroundColor Green
    }
}
finally {
    if (Test-Path $influxJson) { Remove-Item $influxJson -Force -ErrorAction SilentlyContinue }
    if (Test-Path $etlJson) { Remove-Item $etlJson -Force -ErrorAction SilentlyContinue }
}
