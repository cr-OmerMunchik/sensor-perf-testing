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

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "file_storm" `
    -Description "Mass file create/modify/delete ($FileCount files x $Bursts bursts)"

$testRoot = "C:\PerfTest\filestorm"

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

$results | Format-Table -AutoSize

$avgCreate = ($results | Measure-Object -Property CreateSec -Average).Average
$avgModify = ($results | Measure-Object -Property ModifySec -Average).Average
$avgDelete = ($results | Measure-Object -Property DeleteSec -Average).Average
$avgTotal = ($results | Measure-Object -Property TotalSec -Average).Average

Add-ScenarioMetric -Key "files_per_burst" -Value $FileCount
Add-ScenarioMetric -Key "bursts" -Value $Bursts
Add-ScenarioMetric -Key "avg_create_seconds" -Value ([math]::Round($avgCreate, 2))
Add-ScenarioMetric -Key "avg_modify_seconds" -Value ([math]::Round($avgModify, 2))
Add-ScenarioMetric -Key "avg_delete_seconds" -Value ([math]::Round($avgDelete, 2))
Add-ScenarioMetric -Key "avg_total_seconds" -Value ([math]::Round($avgTotal, 2))
Add-ScenarioMetric -Key "total_file_operations" -Value ($FileCount * $Bursts * 3)
Add-ScenarioMetric -Key "expected_events" -Value "FILE_CREATED, FILE_MODIFIED, FILE_DELETED"

# Cleanup
if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue }

Complete-Scenario
