<#
.SYNOPSIS
    Orchestrates InfluxDB and ETL analysis, then generates a consolidated performance bottleneck report.

.DESCRIPTION
    Runs influx-analyze.ps1 and EtlAnalyzer, merges findings, and produces a Markdown report.

.PARAMETER TraceDir
    Path to directory containing .etl trace files (default: C:\Users\OmerMunchik\playground\traces\2026-02-23).

.PARAMETER Token
    InfluxDB API token. If not provided, uses $env:INFLUXDB_TOKEN.

.PARAMETER InfluxUrl
    InfluxDB base URL (default: http://172.46.16.24:8086).

.PARAMETER TimeRange
    Flux time range for InfluxDB queries (default: -7d).

.PARAMETER OutputPath
    Path for the generated report. Default: perf-bottleneck-report-YYYYMMDD.md in current directory.

.PARAMETER UseSymbols
    If set, ETL analyzer loads symbols for function names (slower, requires network).

.PARAMETER SkipInfluxDB
    Skip InfluxDB analysis (use when MON VM is unreachable). Report will include ETL data only.

.PARAMETER TraceLimit
    Process only the first N trace files (for quick test). Default: 0 = all traces.

.PARAMETER InfluxJsonPath
    Path to pre-fetched InfluxDB JSON (from running influx-analyze.ps1 on MON VM).
    Use when your workstation cannot reach InfluxDB directly.

.EXAMPLE
    $env:INFLUXDB_TOKEN = "your-token"
    .\generate-perf-report.ps1 -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23"

.EXAMPLE
    # When workstation cannot reach InfluxDB: run influx-analyze on MON VM, copy JSON, then:
    .\generate-perf-report.ps1 -TraceDir "C:\traces\2026-02-23" -InfluxJsonPath "C:\temp\influx-data.json"

.EXAMPLE
    # Quick test: skip InfluxDB, process only 2 traces (~5 min)
    .\generate-perf-report.ps1 -SkipInfluxDB -TraceLimit 2
#>

[CmdletBinding()]
param(
    [string]$TraceDir = "C:\Users\OmerMunchik\playground\traces\2026-02-23",
    [string]$Token = $env:INFLUXDB_TOKEN,
    [string]$InfluxUrl = "http://172.46.16.24:8086",
    [string]$TimeRange = "-7d",
    [string]$OutputPath,
    [switch]$UseSymbols,
    [switch]$SkipInfluxDB,
    [int]$TraceLimit = 0,
    [string]$InfluxJsonPath
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolsDir = Split-Path -Parent $scriptDir

function Build-Report {
    param($InfluxData, $EtlData, [switch]$UseSymbols)

    # Determine top 3 busiest scenarios (by peak CPU from InfluxDB, or ETL total weight if no InfluxDB)
    $top3Scenarios = @()
    if ($InfluxData -and $InfluxData.sensorCpu) {
        $top3Scenarios = $InfluxData.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-3" } | Sort-Object -Property peakCpu -Descending | Select-Object -First 3 -ExpandProperty scenario
    }
    if ($top3Scenarios.Count -eq 0 -and $EtlData -and $EtlData.traces) {
        $top3Scenarios = $EtlData.traces | Where-Object { -not $_.error } | Sort-Object -Property totalWeightMs -Descending | Select-Object -First 3 -ExpandProperty scenario
    }
    if ($top3Scenarios.Count -eq 0 -and $EtlData -and $EtlData.traces) {
        $top3Scenarios = $EtlData.traces | Where-Object { -not $_.error } | ForEach-Object { $_.scenario }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# ActiveProbe Performance Bottleneck Report")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("")

    # --- How to read this report ---
    [void]$sb.AppendLine("## How to Read This Report")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("This report identifies where the ActiveProbe sensor uses too much CPU, memory, or disk I/O during performance tests. **Only the 3 busiest scenarios** (by peak CPU) are included.")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- **CPU %** = How much of one CPU core the sensor used. 100% = one full core. Our target: under 15%.")
    [void]$sb.AppendLine("- **Peak vs Avg** = Peak is the worst moment; avg is over the whole test. Spikes matter for user experience.")
    [void]$sb.AppendLine("- **Top processes** = Which programs used the most CPU during the trace.")
    [void]$sb.AppendLine("- **Top sensor functions** = Which code paths inside the sensor consumed the most CPU. These are the hotspots to optimize.")
    if (-not $UseSymbols) {
        [void]$sb.AppendLine("- **Note:** Function names show as addresses (e.g. ntoskrnl+0x...). Run with `-UseSymbols` for readable names like `KeWaitForSingleObject`.")
    }
    [void]$sb.AppendLine("")

    # --- Key findings in plain English ---
    [void]$sb.AppendLine("## Key Findings (Plain English)")
    [void]$sb.AppendLine("")
    $highCpu = @()
    if ($InfluxData) {
        $highCpu = $InfluxData.sensorCpu | Where-Object { $_.peakCpu -gt 15 -and $_.host -like "*TEST-PERF*" -and ($top3Scenarios.Count -eq 0 -or $top3Scenarios -contains $_.scenario) } | Sort-Object -Property peakCpu -Descending
    }
    if ($highCpu.Count -eq 0) {
        [void]$sb.AppendLine("No scenarios exceeded the 15% CPU target. Sensor performance looks acceptable.")
    } else {
        $worst = $highCpu[0]
        [void]$sb.AppendLine("**Worst scenario:** $($worst.scenario) - sensor peaked at **$([math]::Round($worst.peakCpu, 0))% CPU** (target: under 15%).")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("**Scenarios that need attention:**")
        $seen = @{}
        foreach ($c in $highCpu) {
            if ($seen[$c.scenario]) { continue }
            $seen[$c.scenario] = $true
            $pct = [math]::Round($c.peakCpu, 0)
            $severity = if ($pct -ge 50) { "Critical" } elseif ($pct -ge 30) { "High" } else { "Moderate" }
            [void]$sb.AppendLine("- **$($c.scenario)**: $pct% peak CPU ($severity)")
        }
    }
    [void]$sb.AppendLine("")

    # --- Executive summary (technical) ---
    [void]$sb.AppendLine("## Technical Summary")
    [void]$sb.AppendLine("")
    $bottlenecks = @()
    if ($InfluxData) {
        $cpuFailures = $InfluxData.kpiFailures | Where-Object { $_.type -eq "cpu" -and $_.host -like "*TEST-PERF*" -and ($top3Scenarios.Count -eq 0 -or $top3Scenarios -contains $_.scenario) }
        foreach ($k in $cpuFailures) {
            $bottlenecks += "$($k.scenario) on $($k.host): $([math]::Round($k.value, 1))% CPU (threshold: $($k.threshold)%)"
        }
    }
    if ($EtlData -and $EtlData.traces) {
        $tracesFiltered = if ($top3Scenarios.Count -gt 0) { $EtlData.traces | Where-Object { $top3Scenarios -contains $_.scenario } } else { $EtlData.traces }
        foreach ($t in $tracesFiltered) {
            if ($t.error) { continue }
            foreach ($f in $t.topFunctions) {
                $pct = [double]$f.percent
                if ($pct -ge 10) {
                    $fn = if ($f.module -and $f.function) { "$($f.module): $($f.function)" } elseif ($f.function -match '^([^!]+)!(.+)$') { "$($Matches[1]): $($Matches[2])" } else { $f.function }
                    $bottlenecks += "[ETL] $($t.scenario): $fn - $pct% of trace"
                }
            }
        }
    }
    if ($bottlenecks.Count -eq 0) {
        [void]$sb.AppendLine("No major bottlenecks above thresholds.")
    } else {
        foreach ($b in $bottlenecks) {
            [void]$sb.AppendLine("- $b")
        }
    }
    [void]$sb.AppendLine("")

    # --- InfluxDB findings ---
    [void]$sb.AppendLine("## Metrics by Test Scenario (from InfluxDB)")
    [void]$sb.AppendLine("")
    if (-not $InfluxData) {
        [void]$sb.AppendLine("No InfluxDB data available.")
    } else {
        $sensorVm = $InfluxData.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-3" }
        if ($top3Scenarios.Count -gt 0) { $sensorVm = $sensorVm | Where-Object { $top3Scenarios -contains $_.scenario } }
        [void]$sb.AppendLine("### CPU")
        [void]$sb.AppendLine("Peak CPU = highest moment during the test. Target: under 15%.")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| Scenario | Peak CPU (Percent) | Status |")
        [void]$sb.AppendLine("|----------|---------------------|--------|")
        foreach ($c in ($sensorVm | Sort-Object -Property scenario | ForEach-Object { $_.scenario })) {
            $row = $sensorVm | Where-Object { $_.scenario -eq $c } | Select-Object -First 1
            $pct = [math]::Round($row.peakCpu, 1)
            $status = if ($pct -gt 15) { "Over target" } else { "OK" }
            [void]$sb.AppendLine("| $c | $pct | $status |")
        }

        # Memory
        $sensorMem = $InfluxData.sensorMemory | Where-Object { $_.host -eq "TEST-PERF-3" }
        if ($top3Scenarios.Count -gt 0) { $sensorMem = $sensorMem | Where-Object { $top3Scenarios -contains $_.scenario } }
        if ($sensorMem.Count -gt 0) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("### Sensor Memory")
            [void]$sb.AppendLine("| Scenario | Working Set (MB) |")
            [void]$sb.AppendLine("|----------|-----------------|")
            foreach ($m in ($sensorMem | Sort-Object -Property scenario)) {
                [void]$sb.AppendLine("| $($m.scenario) | $([math]::Round($m.avgMemMB, 1)) |")
            }
        }

        # Disk I/O
        $disk = $InfluxData.diskIo | Where-Object { $_.host -eq "TEST-PERF-3" }
        if ($top3Scenarios.Count -gt 0) { $disk = $disk | Where-Object { $top3Scenarios -contains $_.scenario } }
        if ($disk.Count -gt 0) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("### Disk I/O")
            [void]$sb.AppendLine("| Scenario | Read (B/s) | Write (B/s) |")
            [void]$sb.AppendLine("|----------|------------|-------------|")
            foreach ($d in ($disk | Sort-Object -Property scenario)) {
                [void]$sb.AppendLine("| $($d.scenario) | $([math]::Round($d.readBps, 0)) | $([math]::Round($d.writeBps, 0)) |")
            }
        }

        # Sensor vs no-sensor comparison
        $deltas = if ($top3Scenarios.Count -gt 0) { $InfluxData.sensorDeltas | Where-Object { $top3Scenarios -contains $_.scenario } } else { $InfluxData.sensorDeltas }
        if ($deltas.Count -gt 0) {
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("### System Overload: With vs Without Sensor")
            [void]$sb.AppendLine("Comparison of TEST-PERF-3 (sensor) vs TEST-PERF-4 (no sensor). Positive values = sensor adds overhead.")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("| Scenario | Sensor CPU Delta (Percent) | System CPU Delta | Sensor Memory (MB) | System Mem Delta (MB) | Disk Read Delta (B/s) | Disk Write Delta (B/s) |")
            [void]$sb.AppendLine("|----------|----------------------------|------------------|-------------------|----------------------|----------------------|-----------------------|")
            foreach ($d in $deltas) {
                $cpuD = [math]::Round($d.cpuDelta, 1)
                $sysCpuD = [math]::Round($d.sysCpuDelta, 1)
                $memD = [math]::Round($d.memDeltaMB, 1)
                $sysMemD = [math]::Round($d.sysMemDeltaMB, 1)
                $rdD = [math]::Round($d.diskReadDeltaBps, 0)
                $wrD = [math]::Round($d.diskWriteDeltaBps, 0)
                [void]$sb.AppendLine("| $($d.scenario) | +$cpuD | +$sysCpuD | +$memD | +$sysMemD | +$rdD | +$wrD |")
            }
        }
    }
    [void]$sb.AppendLine("")

    # --- ETL findings ---
    [void]$sb.AppendLine("## ETL Trace Analysis (CPU Hotspots)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Each trace shows which processes and which code paths used the most CPU. The Top sensor functions are the hotspots inside the sensor - these are the functions to optimize first.")
    [void]$sb.AppendLine("")
    if (-not $EtlData -or -not $EtlData.traces) {
        [void]$sb.AppendLine("No ETL trace data available.")
    } else {
        $tracesToShow = if ($top3Scenarios.Count -gt 0) { $EtlData.traces | Where-Object { $top3Scenarios -contains $_.scenario } } else { $EtlData.traces }
        foreach ($t in $tracesToShow) {
            if ($t.error) {
                [void]$sb.AppendLine("### $($t.scenario) - Error")
                [void]$sb.AppendLine($t.error)
                [void]$sb.AppendLine("")
                continue
            }
            [void]$sb.AppendLine("### $($t.scenario)")
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Top processes (who used CPU):**")
            [void]$sb.AppendLine("| Process | CPU time (ms) | Percent |")
            [void]$sb.AppendLine("|---------|---------------|---------|")
            foreach ($p in $t.topProcesses) {
                [void]$sb.AppendLine("| $($p.process) | $($p.weightMs) | $($p.percent)% |")
            }
            [void]$sb.AppendLine("")
            [void]$sb.AppendLine("**Top sensor code hotspots (where to optimize):**")
            [void]$sb.AppendLine("| Module | Function | CPU time (ms) | Percent |")
            [void]$sb.AppendLine("|--------|----------|---------------|---------|")
            foreach ($f in $t.topFunctions) {
                $mod = $f.module
                $fn = $f.function
                if (-not $mod -and $f.PSObject.Properties['function'] -and $f.function -match '^([^!]+)!(.+)$') {
                    $mod = $Matches[1]; $fn = $Matches[2]
                }
                if (-not $mod) { $mod = "-" }; if (-not $fn) { $fn = "-" }
                [void]$sb.AppendLine("| $mod | $fn | $($f.weightMs) | $($f.percent)% |")
            }
            [void]$sb.AppendLine("")
        }
    }

    return $sb.ToString()
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $toolsDir "perf-bottleneck-report-$(Get-Date -Format 'yyyyMMdd').md"
}

# Temp files for intermediate JSON
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
    if (-not (Test-Path $etlProject)) {
        throw "EtlAnalyzer project not found at $etlProject"
    }
    if (-not (Test-Path $TraceDir)) {
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

    # --- Part 3: Generate report ---
    Write-Host "Generating report..." -ForegroundColor Cyan
    $report = Build-Report -InfluxData $influxData -EtlData $etlData -UseSymbols:$UseSymbols | Out-String
    $report | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host "Report written to: $OutputPath" -ForegroundColor Green
}
finally {
    if (Test-Path $influxJson) { Remove-Item $influxJson -Force -ErrorAction SilentlyContinue }
    if (Test-Path $etlJson) { Remove-Item $etlJson -Force -ErrorAction SilentlyContinue }
}
