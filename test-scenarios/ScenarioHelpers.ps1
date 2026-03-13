<#
.SYNOPSIS
    Shared helper functions for all test scenarios.

.DESCRIPTION
    Provides a standard interface for scenario execution:
      - Start-Scenario    : Tags metrics, logs start time, optionally starts WPR trace and metrics sampler
      - Add-ScenarioMetric: Records a key-value metric
      - Complete-Scenario : Logs end time, stops WPR trace, aggregates sampled metrics, writes summary
      - Enable-Profiling  : Enables WPR trace capture for the current session
      - Enable-MetricsCollection : Enables background process metrics sampling

    This module is designed for future LoginVSI integration:
      - Each scenario is a self-contained script with standard parameters
      - Results are output as JSON for machine parsing
      - Entry/exit patterns are consistent for orchestration tooling

.NOTES
    Dot-source this file at the top of each scenario script:
      . "$PSScriptRoot\ScenarioHelpers.ps1"
#>

# ---------- Shared constants ----------
$script:SensorProcessNames = @(
    "minionhost", "ActiveConsole", "CrsSvc", "PylumLoader",
    "AmSvc", "WscIfSvc", "ExecutionPreventionSvc", "CrAmTray", "Nnx", "CrDrvCtrl"
)

# ---------- Profiling state ----------
# Uses env vars so child scenario scripts (invoked via &) inherit the state from Run-AllScenarios
function Test-ProfilingEnabled {
    return $env:PERF_TEST_PROFILING -eq "1"
}
function Get-ProfilingProfiles {
    if ($env:PERF_TEST_PROFILING_PROFILES) {
        return $env:PERF_TEST_PROFILING_PROFILES -split ","
    }
    return @("GeneralProfile", "DiskIO")
}

# ---------- Metrics collection state ----------
function Test-MetricsCollectionEnabled {
    return $env:PERF_TEST_COLLECT_METRICS -eq "1"
}
function Enable-MetricsCollection {
    $env:PERF_TEST_COLLECT_METRICS = "1"
    Write-Host "[OK] Inline process metrics collection enabled (5s interval)" -ForegroundColor Green
}

function Enable-Profiling {
    param(
        [string[]]$Profiles = @("GeneralProfile", "DiskIO")
    )

    $wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
    if (-not $wpr) {
        Write-Host "[WARN] wpr.exe not found - profiling disabled. Install Windows Performance Toolkit." -ForegroundColor Yellow
        return
    }

    $env:PERF_TEST_PROFILING = "1"
    $env:PERF_TEST_PROFILING_PROFILES = $Profiles -join ","
    New-Item -ItemType Directory -Path "C:\PerfTest\traces" -Force | Out-Null
    Write-Host "[OK] WPR profiling enabled. Profiles: $($Profiles -join ', ')" -ForegroundColor Green
}

function Start-Scenario {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Description = ""
    )

    $script:ScenarioName = $Name
    $script:ScenarioStart = Get-Date
    $script:ScenarioResults = @{}

    # Switch Telegraf tag
    $switchScript = Join-Path $PSScriptRoot "Switch-Scenario.ps1"
    if (Test-Path $switchScript) {
        & $switchScript -Scenario $Name
    }

    # Brief settle time for Telegraf to pick up the new tag
    Start-Sleep -Seconds 3

    # Start WPR trace if profiling is enabled (env var set by Run-AllScenarios)
    $profilingEnabled = Test-ProfilingEnabled
    if ($profilingEnabled) {
        $profiles = Get-ProfilingProfiles
        $statusOutput = cmd /c "wpr.exe -status 2>&1"
        if ($statusOutput -match "WPR is recording") {
            Write-Host "[WARN] WPR already recording - cancelling previous trace." -ForegroundColor Yellow
            cmd /c "wpr.exe -cancel 2>&1" | Out-Null
            Start-Sleep -Seconds 2
        }

        $profileArgs = @()
        foreach ($p in $profiles) {
            $profileArgs += "-start"
            $profileArgs += $p
        }
        & wpr.exe @profileArgs
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] WPR trace started ($($profiles -join ', '))" -ForegroundColor Green
        }
        else {
            Write-Host "[WARN] WPR failed to start (exit code: $LASTEXITCODE). Continuing without profiling." -ForegroundColor Yellow
            $env:PERF_TEST_PROFILING = "0"
        }
    }

    # Start background metrics sampler if enabled (uses in-process runspace
    # to inherit the caller's security context and see all processes)
    $script:MetricsSamplerRunspace = $null
    $script:MetricsSamplerPipeline = $null
    $script:MetricsSamplerOutput   = $null
    if (Test-MetricsCollectionEnabled) {
        $procNames = $script:SensorProcessNames
        $script:MetricsSamplerOutput = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
        $outputBag = $script:MetricsSamplerOutput

        # Discover sensor DB path once before starting the sampler
        $dbPath = $null
        $dbSearchPaths = @(
            "C:\ProgramData\apv2\Database",
            "C:\ProgramData\Cybereason\ActiveProbe\data",
            "C:\ProgramData\Crs",
            "C:\ProgramData\Cybereason"
        )
        $dbFilters = @("CrCorrelationDB.sqlite", "*.sqlite", "*.db")
        foreach ($sp in $dbSearchPaths) {
            if (Test-Path $sp) {
                foreach ($filter in $dbFilters) {
                    $found = Get-ChildItem $sp -Filter $filter -Recurse -ErrorAction SilentlyContinue | Sort-Object Length -Descending | Select-Object -First 1
                    if ($found) { $dbPath = $found.FullName; break }
                }
                if ($dbPath) { break }
            }
        }

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('ProcessNames', $procNames)
        $rs.SessionStateProxy.SetVariable('IntervalMs', 5000)
        $rs.SessionStateProxy.SetVariable('OutputBag', $outputBag)
        $rs.SessionStateProxy.SetVariable('DbFilePath', $dbPath)

        $ps = [powershell]::Create().AddScript({
            $prevCpuTimes = @{}
            $counterPaths = @(
                '\Processor(_Total)\% Processor Time',
                '\Memory\Available MBytes',
                '\PhysicalDisk(_Total)\Disk Write Bytes/sec'
            )
            while ($true) {
                $ts = Get-Date
                $sampleEntry = @{ timestamp = $ts.ToString('o'); processes = @{} }

                foreach ($pn in $ProcessNames) {
                    $procs = Get-Process -Name $pn -ErrorAction SilentlyContinue
                    if ($procs) {
                        $totalCpuMs = ($procs | ForEach-Object { $_.TotalProcessorTime.TotalMilliseconds } | Measure-Object -Sum).Sum
                        $totalWsMb  = [math]::Round(($procs | ForEach-Object { $_.WorkingSet64 } | Measure-Object -Sum).Sum / 1MB, 1)

                        $cpuPercent = 0.0
                        if ($prevCpuTimes.ContainsKey($pn)) {
                            $deltaCpuMs = $totalCpuMs - $prevCpuTimes[$pn].cpuMs
                            $deltaWallMs = ($ts - $prevCpuTimes[$pn].time).TotalMilliseconds
                            $numCores = [Environment]::ProcessorCount
                            if ($deltaWallMs -gt 0 -and $numCores -gt 0) {
                                $cpuPercent = [math]::Round(($deltaCpuMs / $deltaWallMs / $numCores) * 100, 2)
                            }
                        }
                        $prevCpuTimes[$pn] = @{ cpuMs = $totalCpuMs; time = $ts }

                        $uptimeMin = -1
                        $pid_ = -1
                        try {
                            $oldest = $procs | Sort-Object StartTime | Select-Object -First 1
                            $uptimeMin = [math]::Round(($ts - $oldest.StartTime).TotalMinutes, 1)
                            $pid_ = $oldest.Id
                        } catch {}

                        $sampleEntry.processes[$pn] = @{
                            cpuPercent = $cpuPercent
                            memoryMb   = $totalWsMb
                            uptimeMin  = $uptimeMin
                            pid        = $pid_
                        }
                    }
                }

                try {
                    $counters = (Get-Counter $counterPaths -ErrorAction Stop).CounterSamples
                    $sampleEntry['systemCpuPercent']  = [math]::Round($counters[0].CookedValue, 2)
                    $sampleEntry['availableMemMb']    = [math]::Round($counters[1].CookedValue, 0)
                    $sampleEntry['diskWriteKBps']     = [math]::Round($counters[2].CookedValue / 1024, 1)
                } catch {
                    $sampleEntry['systemCpuPercent'] = -1
                    $sampleEntry['availableMemMb']   = -1
                    $sampleEntry['diskWriteKBps']    = -1
                }

                if ($DbFilePath) {
                    try {
                        $sampleEntry['dbSizeMb'] = [math]::Round((Get-Item $DbFilePath -ErrorAction Stop).Length / 1MB, 1)
                    } catch {
                        $sampleEntry['dbSizeMb'] = -1
                    }
                }

                $OutputBag.Add($sampleEntry)
                Start-Sleep -Milliseconds $IntervalMs
            }
        })
        $ps.Runspace = $rs
        $script:MetricsSamplerPipeline = $ps
        $script:MetricsSamplerRunspace = $rs
        $ps.BeginInvoke() | Out-Null
        Write-Host "[OK] Background metrics sampler started" -ForegroundColor Green
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " Scenario: $Name" -ForegroundColor Cyan
    if ($Description) { Write-Host " $Description" -ForegroundColor Gray }
    Write-Host " Host: $env:COMPUTERNAME" -ForegroundColor White
    Write-Host " Profiling: $(if (Test-ProfilingEnabled) { 'ON' } else { 'OFF' })" -ForegroundColor White
    Write-Host " Metrics: $(if (Test-MetricsCollectionEnabled) { 'ON' } else { 'OFF' })" -ForegroundColor White
    Write-Host " Started: $($script:ScenarioStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Add-ScenarioMetric {
    param(
        [Parameter(Mandatory)]
        [string]$Key,
        [Parameter(Mandatory)]
        $Value
    )
    $script:ScenarioResults[$Key] = $Value
}

function Complete-Scenario {
    $endTime = Get-Date
    $duration = ($endTime - $script:ScenarioStart).TotalSeconds

    # Stop background metrics sampler and aggregate results
    if ($script:MetricsSamplerPipeline) {
        $script:MetricsSamplerPipeline.Stop()
        $script:MetricsSamplerPipeline.Dispose()
        $script:MetricsSamplerRunspace.Close()
        $script:MetricsSamplerRunspace.Dispose()
        $rawSamples = @($script:MetricsSamplerOutput.ToArray())

        if ($rawSamples -and $rawSamples.Count -gt 1) {
            $rawSamples = $rawSamples | Sort-Object { $_.timestamp }
            $skipFirst = if ($rawSamples.Count -gt 2) { 1 } else { 0 }
            $validSamples = @($rawSamples | Select-Object -Skip $skipFirst)
            $sampleCount = $validSamples.Count
            Write-Host "[OK] Metrics sampler stopped - collected $sampleCount samples" -ForegroundColor Green

            $processMetrics = @{}
            $sysCpuValues = [System.Collections.Generic.List[double]]::new()
            $availMemValues = [System.Collections.Generic.List[double]]::new()
            $diskWriteValues = [System.Collections.Generic.List[double]]::new()
            $lastDbSizeMb = -1
            $processPids = @{}

            foreach ($sample in $validSamples) {
                if ($sample.systemCpuPercent -ge 0) {
                    $sysCpuValues.Add($sample.systemCpuPercent)
                }
                if ($sample.availableMemMb -ge 0) {
                    $availMemValues.Add($sample.availableMemMb)
                }
                if ($sample.diskWriteKBps -ge 0) {
                    $diskWriteValues.Add($sample.diskWriteKBps)
                }
                if ($sample.dbSizeMb -gt 0) {
                    $lastDbSizeMb = $sample.dbSizeMb
                }
                if ($sample.processes) {
                    foreach ($procName in $sample.processes.Keys) {
                        if (-not $processMetrics.ContainsKey($procName)) {
                            $processMetrics[$procName] = @{
                                cpuValues = [System.Collections.Generic.List[double]]::new()
                                memValues = [System.Collections.Generic.List[double]]::new()
                            }
                        }
                        $processMetrics[$procName].cpuValues.Add($sample.processes[$procName].cpuPercent)
                        $processMetrics[$procName].memValues.Add($sample.processes[$procName].memoryMb)
                        if ($sample.processes[$procName].pid -gt 0) {
                            if (-not $processPids.ContainsKey($procName)) {
                                $processPids[$procName] = [System.Collections.Generic.List[int]]::new()
                            }
                            $curPid = [int]$sample.processes[$procName].pid
                            if ($processPids[$procName].Count -eq 0 -or $processPids[$procName][$processPids[$procName].Count - 1] -ne $curPid) {
                                $processPids[$procName].Add($curPid)
                            }
                        }
                    }
                }
            }

            $procSummaries = @{}
            foreach ($pn in $processMetrics.Keys) {
                $cpu = $processMetrics[$pn].cpuValues
                $mem = $processMetrics[$pn].memValues
                $restarts = if ($processPids.ContainsKey($pn)) { [math]::Max(0, $processPids[$pn].Count - 1) } else { 0 }
                $lastSample = $validSamples[-1]
                $uptimeMin = -1
                if ($lastSample.processes -and $lastSample.processes[$pn] -and $lastSample.processes[$pn].uptimeMin -ge 0) {
                    $uptimeMin = $lastSample.processes[$pn].uptimeMin
                }
                $procSummaries[$pn] = @{
                    avg_cpu_percent  = [math]::Round(($cpu | Measure-Object -Average).Average, 2)
                    peak_cpu_percent = [math]::Round(($cpu | Measure-Object -Maximum).Maximum, 2)
                    avg_memory_mb    = [math]::Round(($mem | Measure-Object -Average).Average, 1)
                    peak_memory_mb   = [math]::Round(($mem | Measure-Object -Maximum).Maximum, 1)
                    uptime_minutes   = $uptimeMin
                    restarts         = $restarts
                }
            }

            Add-ScenarioMetric -Key "process_metrics" -Value $procSummaries
            Add-ScenarioMetric -Key "metrics_sample_count" -Value $sampleCount

            if ($sysCpuValues.Count -gt 0) {
                Add-ScenarioMetric -Key "system_avg_cpu_percent" -Value ([math]::Round(($sysCpuValues | Measure-Object -Average).Average, 2))
                Add-ScenarioMetric -Key "system_peak_cpu_percent" -Value ([math]::Round(($sysCpuValues | Measure-Object -Maximum).Maximum, 2))
            }

            if ($availMemValues.Count -gt 0) {
                $totalMemMb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB, 0)
                Add-ScenarioMetric -Key "system_total_memory_mb" -Value $totalMemMb
                $avgAvail = [math]::Round(($availMemValues | Measure-Object -Average).Average, 0)
                $minAvail = [math]::Round(($availMemValues | Measure-Object -Minimum).Minimum, 0)
                Add-ScenarioMetric -Key "system_available_memory_avg_mb" -Value $avgAvail
                Add-ScenarioMetric -Key "system_used_memory_avg_mb" -Value ($totalMemMb - $avgAvail)
                Add-ScenarioMetric -Key "system_used_memory_peak_mb" -Value ($totalMemMb - $minAvail)
            }

            if ($diskWriteValues.Count -gt 0) {
                Add-ScenarioMetric -Key "disk_write_avg_kbps" -Value ([math]::Round(($diskWriteValues | Measure-Object -Average).Average, 1))
                Add-ScenarioMetric -Key "disk_write_peak_kbps" -Value ([math]::Round(($diskWriteValues | Measure-Object -Maximum).Maximum, 1))
            }

            if ($lastDbSizeMb -gt 0) {
                Add-ScenarioMetric -Key "sensor_db_size_mb" -Value $lastDbSizeMb
            }

            $totalSensorCpu = 0.0
            foreach ($pn in $script:SensorProcessNames) {
                if ($procSummaries.ContainsKey($pn)) {
                    $totalSensorCpu += $procSummaries[$pn].avg_cpu_percent
                }
            }
            Add-ScenarioMetric -Key "total_sensor_avg_cpu_percent" -Value ([math]::Round($totalSensorCpu, 2))
        } else {
            Write-Host "[WARN] Metrics sampler returned no usable data" -ForegroundColor Yellow
        }
        $script:MetricsSamplerPipeline = $null
        $script:MetricsSamplerRunspace = $null
        $script:MetricsSamplerOutput   = $null
    }

    # Stop WPR trace if profiling was active
    $profilingEnabled = Test-ProfilingEnabled
    if ($profilingEnabled) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $etlFile = "C:\PerfTest\traces\$($script:ScenarioName)_${env:COMPUTERNAME}_${timestamp}.etl"

        Write-Host "Stopping WPR trace..." -ForegroundColor Cyan
        $wprSuccess = $false
        $savedEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $wprOut = cmd /c "wpr.exe -stop `"$etlFile`" 2>&1"
            if ($LASTEXITCODE -eq 0) {
                $wprSuccess = $true
                break
            }
            if ($attempt -lt 3) {
                Write-Host "[WARN] WPR stop attempt $attempt failed (exit code: $LASTEXITCODE). Retrying in 5s..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            }
        }
        $ErrorActionPreference = $savedEAP
        if ($wprSuccess) {
            $fileSize = [math]::Round((Get-Item $etlFile).Length / 1MB, 1)
            Write-Host "[OK] Trace saved: $etlFile ($fileSize MB)" -ForegroundColor Green
            Add-ScenarioMetric -Key "wpr_trace_file" -Value $etlFile
            Add-ScenarioMetric -Key "wpr_trace_size_mb" -Value $fileSize
        }
        else {
            Write-Host "[WARN] WPR failed to stop after 3 attempts (exit code: $LASTEXITCODE)." -ForegroundColor Yellow
        }
    }

    Add-ScenarioMetric -Key "duration_seconds" -Value ([math]::Round($duration, 2))
    Add-ScenarioMetric -Key "host" -Value $env:COMPUTERNAME
    Add-ScenarioMetric -Key "scenario" -Value $script:ScenarioName
    Add-ScenarioMetric -Key "start_time" -Value $script:ScenarioStart.ToString('o')
    Add-ScenarioMetric -Key "end_time" -Value $endTime.ToString('o')
    Add-ScenarioMetric -Key "profiling_enabled" -Value $profilingEnabled
    Add-ScenarioMetric -Key "metrics_collection_enabled" -Value (Test-MetricsCollectionEnabled)
    Add-ScenarioMetric -Key "num_cores" -Value ([Environment]::ProcessorCount)

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host " Scenario Complete: $($script:ScenarioName)" -ForegroundColor Green
    Write-Host " Duration: $([math]::Round($duration, 1)) seconds" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Green

    # Print results table
    $script:ScenarioResults.GetEnumerator() | Sort-Object Name | Format-Table Name, Value -AutoSize

    # Save results as JSON for machine parsing (LoginVSI or other orchestrators)
    $resultsDir = "C:\PerfTest\results"
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $jsonFile = "$resultsDir\$($script:ScenarioName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $script:ScenarioResults | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
    Write-Host "Results saved to: $jsonFile" -ForegroundColor Yellow
}
