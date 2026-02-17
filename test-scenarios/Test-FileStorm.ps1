<#
.SYNOPSIS
    Runs the File Storm test scenario.

.DESCRIPTION
    Creates a burst of file system activity: mass file creation, modification,
    and deletion. This stresses the sensor's file system monitoring (minifilter).

    Run this on BOTH VMs to compare with/without sensor.

.PARAMETER FileCount
    Number of files to create per burst. Default: 5000.

.PARAMETER Bursts
    Number of create/delete bursts to run. Default: 5.

.EXAMPLE
    .\Test-FileStorm.ps1
    .\Test-FileStorm.ps1 -FileCount 10000 -Bursts 10
#>

param(
    [int]$FileCount = 5000,
    [int]$Bursts = 5
)

$ErrorActionPreference = "Stop"

$testRoot = "C:\PerfTest\filestorm"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " File Storm Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Host       : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  Files/burst: $FileCount" -ForegroundColor White
Write-Host "  Bursts     : $Bursts" -ForegroundColor White

# Switch scenario tag
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$scriptDir\Switch-Scenario.ps1" -Scenario "file_storm"

Start-Sleep -Seconds 5

$results = @()
for ($burst = 1; $burst -le $Bursts; $burst++) {
    Write-Host "`n--- Burst $burst of $Bursts ---" -ForegroundColor Cyan

    $burstDir = "$testRoot\burst_$burst"
    New-Item -ItemType Directory -Path $burstDir -Force | Out-Null

    # CREATE phase
    Write-Host "  Creating $FileCount files..." -ForegroundColor White -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $FileCount; $i++) {
        [System.IO.File]::WriteAllText("$burstDir\file_$i.txt", "test content iteration $i burst $burst timestamp $(Get-Date -Format 'o')")
    }
    $sw.Stop()
    $createTime = $sw.Elapsed.TotalSeconds
    Write-Host " $([math]::Round($createTime, 2))s" -ForegroundColor Green

    # MODIFY phase
    Write-Host "  Modifying $FileCount files..." -ForegroundColor White -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 1; $i -le $FileCount; $i++) {
        [System.IO.File]::AppendAllText("$burstDir\file_$i.txt", " modified at $(Get-Date -Format 'o')")
    }
    $sw.Stop()
    $modifyTime = $sw.Elapsed.TotalSeconds
    Write-Host " $([math]::Round($modifyTime, 2))s" -ForegroundColor Green

    # DELETE phase
    Write-Host "  Deleting $FileCount files..." -ForegroundColor White -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Remove-Item "$burstDir" -Recurse -Force
    $sw.Stop()
    $deleteTime = $sw.Elapsed.TotalSeconds
    Write-Host " $([math]::Round($deleteTime, 2))s" -ForegroundColor Green

    $results += [PSCustomObject]@{
        Burst      = $burst
        CreateSec  = [math]::Round($createTime, 2)
        ModifySec  = [math]::Round($modifyTime, 2)
        DeleteSec  = [math]::Round($deleteTime, 2)
        TotalSec   = [math]::Round($createTime + $modifyTime + $deleteTime, 2)
    }

    # Brief pause between bursts to see recovery in graphs
    if ($burst -lt $Bursts) {
        Write-Host "  Pausing 10 seconds before next burst..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
    }
}

# ---------- Results ----------
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " File Storm Test COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
$results | Format-Table -AutoSize

$avgTotal = ($results | Measure-Object -Property TotalSec -Average).Average
Write-Host "Average total time per burst: $([math]::Round($avgTotal, 2)) seconds" -ForegroundColor Cyan

$resultsFile = "C:\PerfTest\results_file_storm_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$results | Format-Table -AutoSize | Out-File $resultsFile
Write-Host "`nResults saved to: $resultsFile" -ForegroundColor Yellow

# Cleanup
if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
