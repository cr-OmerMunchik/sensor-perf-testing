<#
.SYNOPSIS
    Runs the ZIP Extraction workload comparison test.

.DESCRIPTION
    Sets the scenario tag to "zip_extraction", creates a test ZIP file with
    10,000 files, then extracts it. Measures elapsed time.

    Run this on BOTH VMs simultaneously to compare with/without sensor.

.PARAMETER FileCount
    Number of files in the test ZIP. Default: 10000.

.PARAMETER FileSizeBytes
    Size of each file in bytes. Default: 1024 (1 KB).

.PARAMETER Iterations
    Number of times to repeat the extraction. Default: 3.

.EXAMPLE
    .\Test-ZipExtraction.ps1
    .\Test-ZipExtraction.ps1 -FileCount 20000 -Iterations 5
#>

param(
    [int]$FileCount = 10000,
    [int]$FileSizeBytes = 1024,
    [int]$Iterations = 3
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "zip_extraction" `
    -Description "ZIP extraction ($FileCount files x $Iterations iterations)"

$testRoot = "C:\PerfTest"
$sourceDir = "$testRoot\source"
$zipFile = "$testRoot\test_${FileCount}_files.zip"
$outputDir = "$testRoot\output"

# ---------- Create test data (if needed) ----------
if (-not (Test-Path $zipFile)) {
    Write-Host "`n[1/3] Creating test data ($FileCount files)..." -ForegroundColor White
    New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null

    $content = "x" * $FileSizeBytes
    for ($i = 1; $i -le $FileCount; $i++) {
        Set-Content "$sourceDir\file_$i.txt" $content
        if ($i % 1000 -eq 0) {
            Write-Host "      Created $i / $FileCount files..." -ForegroundColor Gray
        }
    }

    Write-Host "      Creating ZIP archive..." -ForegroundColor Gray
    if (Test-Path $zipFile) { Remove-Item $zipFile -Force }
    Compress-Archive -Path "$sourceDir\*" -DestinationPath $zipFile -CompressionLevel Fastest
    Write-Host "      ZIP created: $zipFile ($([math]::Round((Get-Item $zipFile).Length / 1MB, 1)) MB)" -ForegroundColor Gray
}
else {
    Write-Host "`n[1/3] Test ZIP already exists: $zipFile" -ForegroundColor Gray
}

# ---------- Warm-up run ----------
Write-Host "`n[2/3] Warm-up extraction (not timed)..." -ForegroundColor White
if (Test-Path $outputDir) { Remove-Item $outputDir -Recurse -Force }
Expand-Archive $zipFile -DestinationPath $outputDir -Force
Remove-Item $outputDir -Recurse -Force
Write-Host "      Warm-up complete." -ForegroundColor Gray

# ---------- Timed runs ----------
Write-Host "`n[3/3] Running $Iterations timed extractions..." -ForegroundColor White

$results = @()
for ($iter = 1; $iter -le $Iterations; $iter++) {
    if (Test-Path $outputDir) { Remove-Item $outputDir -Recurse -Force }

    Write-Host "      Iteration $iter of $Iterations..." -ForegroundColor Gray -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Expand-Archive $zipFile -DestinationPath $outputDir -Force
    $sw.Stop()

    $elapsed = $sw.Elapsed.TotalSeconds
    $results += $elapsed
    Write-Host " $([math]::Round($elapsed, 2)) seconds" -ForegroundColor White

    if ($iter -lt $Iterations) {
        Remove-Item $outputDir -Recurse -Force
        Start-Sleep -Seconds 5
    }
}

# ---------- Results ----------
$avg = ($results | Measure-Object -Average).Average
$min = ($results | Measure-Object -Minimum).Minimum
$max = ($results | Measure-Object -Maximum).Maximum

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " ZIP Extraction Test COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Host       : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  Files      : $FileCount" -ForegroundColor White
Write-Host "  Iterations : $Iterations" -ForegroundColor White
Write-Host "" -ForegroundColor White
Write-Host "  Average    : $([math]::Round($avg, 2)) seconds" -ForegroundColor Cyan
Write-Host "  Min        : $([math]::Round($min, 2)) seconds" -ForegroundColor White
Write-Host "  Max        : $([math]::Round($max, 2)) seconds" -ForegroundColor White
Write-Host ""

Add-ScenarioMetric -Key "file_count" -Value $FileCount
Add-ScenarioMetric -Key "file_size_bytes" -Value $FileSizeBytes
Add-ScenarioMetric -Key "iterations" -Value $Iterations
Add-ScenarioMetric -Key "avg_extraction_seconds" -Value ([math]::Round($avg, 2))
Add-ScenarioMetric -Key "min_extraction_seconds" -Value ([math]::Round($min, 2))
Add-ScenarioMetric -Key "max_extraction_seconds" -Value ([math]::Round($max, 2))
Add-ScenarioMetric -Key "expected_events" -Value "FILE_CREATED, PROCESS_CREATED, MODULE_LOADED"
Add-ScenarioMetric -Key "estimated_file_events" -Value ($FileCount * $Iterations)

# Cleanup
Remove-Item $outputDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $sourceDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipFile -Force -ErrorAction SilentlyContinue

Complete-Scenario
