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

$testRoot = "C:\PerfTest"
$sourceDir = "$testRoot\source"
$zipFile = "$testRoot\test_${FileCount}_files.zip"
$outputDir = "$testRoot\output"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " ZIP Extraction Performance Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Host       : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "  Files      : $FileCount x $FileSizeBytes bytes" -ForegroundColor White
Write-Host "  Iterations : $Iterations" -ForegroundColor White

# Switch scenario tag
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$scriptDir\Switch-Scenario.ps1" -Scenario "zip_extraction"

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

$resultsFile = "$testRoot\results_zip_extraction_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$resultText = @"
ZIP Extraction Test Results
===========================
Host       : $env:COMPUTERNAME
Date       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Files      : $FileCount x $FileSizeBytes bytes
Iterations : $Iterations

Results (seconds):
$($results | ForEach-Object { "  Iteration: $([math]::Round($_, 2))" } | Out-String)
Average    : $([math]::Round($avg, 2))
Min        : $([math]::Round($min, 2))
Max        : $([math]::Round($max, 2))
"@
Set-Content -Path $resultsFile -Value $resultText
Write-Host "Results saved to: $resultsFile" -ForegroundColor Yellow
Write-Host ""
Write-Host "Compare with the other VM's results in Grafana:" -ForegroundColor Yellow
Write-Host "  Select scenario 'zip_extraction' and overlay both hosts." -ForegroundColor White
