<#
.SYNOPSIS
    Collects WPR trace files (.etl) from test VMs to your local workstation.

.DESCRIPTION
    SCPs .etl trace files from one or more test VMs to a local directory,
    organized by date. Optionally cleans up traces on the VM after copying.

    Run this script from your workstation (not on the VMs).

.PARAMETER VMs
    Array of VM IP addresses to collect from.
    Default: test_perf_3 (sensor) and test_perf_4 (no sensor).

.PARAMETER LocalDir
    Local directory to store collected traces.
    Default: C:\PerfTest\collected-traces

.PARAMETER RemoteDir
    Remote directory where traces are stored on the VMs.
    Default: C:\PerfTest\traces

.PARAMETER Cleanup
    If specified, delete traces from the VM after successful copy.

.PARAMETER SshUser
    SSH username for connecting to VMs. Default: admin.

.EXAMPLE
    .\Collect-Traces.ps1
    .\Collect-Traces.ps1 -VMs @("172.46.16.176") -Cleanup
    .\Collect-Traces.ps1 -LocalDir "D:\traces"
#>

param(
    [string[]]$VMs = @("172.46.16.176", "172.46.21.24"),
    [string]$LocalDir = "C:\PerfTest\collected-traces",
    [string]$RemoteDir = "C:\PerfTest\traces",
    [switch]$Cleanup,
    [string]$SshUser = "admin"
)

$ErrorActionPreference = "Stop"

$dateFolder = Get-Date -Format "yyyy-MM-dd"
$destDir = Join-Path $LocalDir $dateFolder
New-Item -ItemType Directory -Path $destDir -Force | Out-Null

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Collecting WPR Traces" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  VMs       : $($VMs -join ', ')" -ForegroundColor White
Write-Host "  Remote dir: $RemoteDir" -ForegroundColor White
Write-Host "  Local dir : $destDir" -ForegroundColor White
Write-Host "  Cleanup   : $Cleanup" -ForegroundColor White
Write-Host ""

$totalFiles = 0

foreach ($vm in $VMs) {
    Write-Host "--- $vm ---" -ForegroundColor Yellow

    # List remote .etl files (use dir /b to avoid cmd.exe pipe interpretation with PowerShell)
    $fileList = ssh "${SshUser}@${vm}" "cmd /c `"dir /b $RemoteDir\*.etl 2>nul`""

    if (-not $fileList) {
        Write-Host "  No .etl files found." -ForegroundColor Gray
        continue
    }

    $files = @($fileList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Host "  Found $($files.Count) trace file(s)" -ForegroundColor White

    foreach ($file in $files) {
        $file = $file.Trim()
        if (-not $file) { continue }

        Write-Host "  Copying: $file ... " -ForegroundColor White -NoNewline
        $remotePath = ($RemoteDir + "\" + $file) -replace '\\', '/'
        $scpOutput = scp "${SshUser}@${vm}:${remotePath}" "$destDir\$file" 2>&1

        if ($LASTEXITCODE -eq 0) {
            $localSize = [math]::Round((Get-Item "$destDir\$file").Length / 1MB, 1)
            Write-Host "OK ($localSize MB)" -ForegroundColor Green
            $totalFiles++

            if ($Cleanup) {
                $remotePathDel = "$RemoteDir\$file"
                ssh "${SshUser}@${vm}" "cmd /c `"del /q `"$remotePathDel`"`"" 2>&1 | Out-Null
                Write-Host "    Cleaned up remote file." -ForegroundColor Gray
            }
        }
        else {
            Write-Host "FAILED" -ForegroundColor Red
            if ($scpOutput) { Write-Host "    $scpOutput" -ForegroundColor Gray }
            Write-Host "    Tip: If 'Permission denied', run PowerShell as Administrator or use a writable -LocalDir." -ForegroundColor Gray
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " Collection Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Files collected: $totalFiles" -ForegroundColor White
Write-Host "  Saved to       : $destDir" -ForegroundColor White
Write-Host ""
Write-Host "Next: Open .etl files in WPA (Windows Performance Analyzer)" -ForegroundColor Yellow
