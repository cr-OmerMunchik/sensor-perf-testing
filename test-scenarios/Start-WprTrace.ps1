#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Standalone WPR (Windows Performance Recorder) trace control for ad-hoc profiling.

.DESCRIPTION
    Start, stop, or check status of WPR trace recordings.
    Use this script independently of the scenario framework when you want to
    profile a specific time window or an already-running workload.

    Traces are saved to C:\PerfTest\traces\ and can be analyzed in WPA
    (Windows Performance Analyzer) on your workstation.

.PARAMETER Action
    Start  - Begin a WPR trace recording
    Stop   - Stop the current recording and save the .etl file
    Status - Check if a trace is currently recording
    Cancel - Cancel the current recording without saving

.PARAMETER Profiles
    WPR profiles to record. Default: GeneralProfile, DiskIO.
    Available: CPU, DiskIO, FileIO, Heap, GeneralProfile, Network

.PARAMETER ScenarioName
    Label for the trace file (used in the filename). Default: "adhoc".

.EXAMPLE
    .\Start-WprTrace.ps1 -Action Start
    .\Start-WprTrace.ps1 -Action Stop -ScenarioName "file_storm"
    .\Start-WprTrace.ps1 -Action Start -Profiles CPU,FileIO,Heap
    .\Start-WprTrace.ps1 -Action Status
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet("Start", "Stop", "Status", "Cancel")]
    [string]$Action,

    [ValidateSet("CPU", "DiskIO", "FileIO", "Heap", "GeneralProfile", "Network")]
    [string[]]$Profiles = @("GeneralProfile", "DiskIO"),

    [string]$ScenarioName = "adhoc"
)

$ErrorActionPreference = "Stop"
$TracesDir = "C:\PerfTest\traces"

function Test-WprAvailable {
    $wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
    if (-not $wpr) {
        Write-Host "[ERROR] wpr.exe not found. Install Windows Performance Toolkit from the Windows ADK." -ForegroundColor Red
        exit 1
    }
}

switch ($Action) {
    "Start" {
        Test-WprAvailable
        New-Item -ItemType Directory -Path $TracesDir -Force | Out-Null

        # Cancel any leftover recording from a previous interrupted run
        $statusOutput = & wpr.exe -status 2>&1
        if ($statusOutput -match "WPR is recording") {
            Write-Host "[WARN] WPR is already recording. Cancelling previous trace..." -ForegroundColor Yellow
            & wpr.exe -cancel 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }

        $profileArgs = @()
        foreach ($p in $Profiles) {
            $profileArgs += "-start"
            $profileArgs += $p
        }

        Write-Host "Starting WPR trace..." -ForegroundColor Cyan
        Write-Host "  Profiles : $($Profiles -join ', ')" -ForegroundColor White
        Write-Host "  Output   : $TracesDir" -ForegroundColor White

        & wpr.exe @profileArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] WPR failed to start (exit code: $LASTEXITCODE)." -ForegroundColor Red
            exit 1
        }

        Write-Host "[OK] WPR trace is recording. Run with -Action Stop when finished." -ForegroundColor Green
    }

    "Stop" {
        Test-WprAvailable
        New-Item -ItemType Directory -Path $TracesDir -Force | Out-Null

        $statusOutput = & wpr.exe -status 2>&1
        if ($statusOutput -notmatch "WPR is recording") {
            Write-Host "[WARN] No active WPR recording to stop." -ForegroundColor Yellow
            exit 0
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $etlFile = Join-Path $TracesDir "${ScenarioName}_${env:COMPUTERNAME}_${timestamp}.etl"

        Write-Host "Stopping WPR trace..." -ForegroundColor Cyan
        Write-Host "  Saving to: $etlFile" -ForegroundColor White

        & wpr.exe -stop $etlFile
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] WPR failed to stop (exit code: $LASTEXITCODE)." -ForegroundColor Red
            exit 1
        }

        $fileSize = [math]::Round((Get-Item $etlFile).Length / 1MB, 1)
        Write-Host "[OK] Trace saved: $etlFile ($fileSize MB)" -ForegroundColor Green
    }

    "Status" {
        Test-WprAvailable
        $statusOutput = & wpr.exe -status 2>&1
        if ($statusOutput -match "WPR is recording") {
            Write-Host "[ACTIVE] WPR is currently recording." -ForegroundColor Yellow
            $statusOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        }
        else {
            Write-Host "[IDLE] No active WPR recording." -ForegroundColor Green
        }
    }

    "Cancel" {
        Test-WprAvailable
        $statusOutput = & wpr.exe -status 2>&1
        if ($statusOutput -notmatch "WPR is recording") {
            Write-Host "[OK] No active WPR recording to cancel." -ForegroundColor Green
            exit 0
        }

        & wpr.exe -cancel
        Write-Host "[OK] WPR recording cancelled (trace discarded)." -ForegroundColor Green
    }
}
