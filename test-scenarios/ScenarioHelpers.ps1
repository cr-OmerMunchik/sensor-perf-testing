<#
.SYNOPSIS
    Shared helper functions for all test scenarios.

.DESCRIPTION
    Provides a standard interface for scenario execution:
      - Start-Scenario    : Tags metrics, logs start time, optionally starts WPR trace
      - Add-ScenarioMetric: Records a key-value metric
      - Complete-Scenario : Logs end time, stops WPR trace, writes summary
      - Enable-Profiling  : Enables WPR trace capture for the current session

    This module is designed for future LoginVSI integration:
      - Each scenario is a self-contained script with standard parameters
      - Results are output as JSON for machine parsing
      - Entry/exit patterns are consistent for orchestration tooling

.NOTES
    Dot-source this file at the top of each scenario script:
      . "$PSScriptRoot\ScenarioHelpers.ps1"
#>

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
        $statusOutput = & wpr.exe -status 2>&1
        if ($statusOutput -match "WPR is recording") {
            Write-Host "[WARN] WPR already recording - cancelling previous trace." -ForegroundColor Yellow
            & wpr.exe -cancel 2>&1 | Out-Null
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

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " Scenario: $Name" -ForegroundColor Cyan
    if ($Description) { Write-Host " $Description" -ForegroundColor Gray }
    Write-Host " Host: $env:COMPUTERNAME" -ForegroundColor White
    Write-Host " Profiling: $(if (Test-ProfilingEnabled) { 'ON' } else { 'OFF' })" -ForegroundColor White
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

    # Stop WPR trace if profiling was active
    $profilingEnabled = Test-ProfilingEnabled
    if ($profilingEnabled) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $etlFile = "C:\PerfTest\traces\$($script:ScenarioName)_${env:COMPUTERNAME}_${timestamp}.etl"

        Write-Host "Stopping WPR trace..." -ForegroundColor Cyan
        & wpr.exe -stop $etlFile
        if ($LASTEXITCODE -eq 0) {
            $fileSize = [math]::Round((Get-Item $etlFile).Length / 1MB, 1)
            Write-Host "[OK] Trace saved: $etlFile ($fileSize MB)" -ForegroundColor Green
            Add-ScenarioMetric -Key "wpr_trace_file" -Value $etlFile
            Add-ScenarioMetric -Key "wpr_trace_size_mb" -Value $fileSize
        }
        else {
            Write-Host "[WARN] WPR failed to stop (exit code: $LASTEXITCODE)." -ForegroundColor Yellow
        }
    }

    Add-ScenarioMetric -Key "duration_seconds" -Value ([math]::Round($duration, 2))
    Add-ScenarioMetric -Key "host" -Value $env:COMPUTERNAME
    Add-ScenarioMetric -Key "scenario" -Value $script:ScenarioName
    Add-ScenarioMetric -Key "start_time" -Value $script:ScenarioStart.ToString('o')
    Add-ScenarioMetric -Key "end_time" -Value $endTime.ToString('o')
    Add-ScenarioMetric -Key "profiling_enabled" -Value $profilingEnabled

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
