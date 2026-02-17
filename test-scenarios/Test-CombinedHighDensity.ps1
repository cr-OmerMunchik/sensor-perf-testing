<#
.SYNOPSIS
    Combined High-Density Scenario (All event types simultaneously)

.DESCRIPTION
    Runs multiple event generators in parallel for maximum multi-event density:
      1. Browser streaming (background)
      2. File stress loop (background)
      3. Registry storm (background)
      4. Network burst (background)

    This generates 10+ event types and 3,000-10,000 total events
    in a single 5-7 minute window.

.PARAMETER DurationSeconds
    Total duration before stopping all generators. Default: 420 (7 minutes).

.PARAMETER FileLoopCount
    Files per cycle in the file stress loop. Default: 1000.

.PARAMETER RegistryLoopCount
    Registry values per cycle. Default: 500.

.PARAMETER NetworkRequestCount
    HTTP requests to send. Default: 200.

.EXAMPLE
    .\Test-CombinedHighDensity.ps1
    .\Test-CombinedHighDensity.ps1 -DurationSeconds 600
#>

param(
    [int]$DurationSeconds = 420,
    [int]$FileLoopCount = 1000,
    [int]$RegistryLoopCount = 500,
    [int]$NetworkRequestCount = 200
)

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "combined_high_density" `
    -Description "All event generators in parallel (${DurationSeconds}s)"

# Prepare directories
$testDir = "C:\PerfTest\combined"
New-Item -ItemType Directory -Path "$testDir\files" -Force | Out-Null
$regPath = "HKCU:\Software\PerfTest_Combined"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }

# ---------- 1. Browser streaming (background) ----------
Write-Host "[1/4] Launching browser streaming..." -ForegroundColor Cyan
$browserProc = Start-Process "msedge.exe" -ArgumentList "https://www.youtube.com/watch?v=dQw4w9WgXcQ" -PassThru

# ---------- 2. File stress loop (background job) ----------
Write-Host "[2/4] Starting file stress loop (background)..." -ForegroundColor Cyan
$fileJob = Start-Job -ScriptBlock {
    param($dir, $count, $durationSec)
    $endTime = (Get-Date).AddSeconds($durationSec)
    $totalOps = 0
    while ((Get-Date) -lt $endTime) {
        for ($i = 1; $i -le $count; $i++) {
            $file = "$dir\test$i.txt"
            $renamed = "$dir\renamed$i.txt"
            [System.IO.File]::WriteAllText($file, "test $i")
            [System.IO.File]::Move($file, $renamed)
            [System.IO.File]::Delete($renamed)
            $totalOps += 3
        }
    }
    $totalOps
} -ArgumentList "$testDir\files", $FileLoopCount, $DurationSeconds

# ---------- 3. Registry storm (background job) ----------
Write-Host "[3/4] Starting registry storm (background)..." -ForegroundColor Cyan
$regJob = Start-Job -ScriptBlock {
    param($path, $count, $durationSec)
    $endTime = (Get-Date).AddSeconds($durationSec)
    $totalOps = 0
    while ((Get-Date) -lt $endTime) {
        for ($i = 1; $i -le $count; $i++) {
            New-ItemProperty -Path $path -Name "Val$i" -Value "test$i" -PropertyType String -Force | Out-Null
            Remove-ItemProperty -Path $path -Name "Val$i" -ErrorAction SilentlyContinue
            $totalOps += 2
        }
    }
    $totalOps
} -ArgumentList $regPath, $RegistryLoopCount, $DurationSeconds

# ---------- 4. Network burst (background job) ----------
Write-Host "[4/4] Starting network burst (background)..." -ForegroundColor Cyan
$netJob = Start-Job -ScriptBlock {
    param($count, $durationSec)
    $endTime = (Get-Date).AddSeconds($durationSec)
    $totalReqs = 0
    while ((Get-Date) -lt $endTime) {
        for ($i = 1; $i -le $count; $i++) {
            try {
                Invoke-WebRequest -Uri "https://example.com" -UseBasicParsing -TimeoutSec 5 | Out-Null
            } catch {}
            $totalReqs++
        }
    }
    $totalReqs
} -ArgumentList $NetworkRequestCount, $DurationSeconds

# ---------- Wait for duration ----------
Write-Host "`nAll generators running. Waiting $DurationSeconds seconds..." -ForegroundColor Yellow
for ($elapsed = 0; $elapsed -lt $DurationSeconds; $elapsed += 15) {
    $remaining = $DurationSeconds - $elapsed
    Write-Progress -Activity "Combined High-Density Scenario" `
        -Status "$remaining seconds remaining - all generators active" `
        -PercentComplete (($elapsed / $DurationSeconds) * 100)
    Start-Sleep -Seconds ([math]::Min(15, $remaining))
}
Write-Progress -Activity "Combined High-Density Scenario" -Completed

# ---------- Stop everything ----------
Write-Host "`nStopping all generators..." -ForegroundColor Cyan

# Stop browser
Stop-Process -Name msedge -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# Collect background job results
$fileOps = Receive-Job $fileJob -Wait -ErrorAction SilentlyContinue
$regOps = Receive-Job $regJob -Wait -ErrorAction SilentlyContinue
$netReqs = Receive-Job $netJob -Wait -ErrorAction SilentlyContinue

Remove-Job $fileJob, $regJob, $netJob -Force -ErrorAction SilentlyContinue

# ---------- Results ----------
Add-ScenarioMetric -Key "duration_target_seconds" -Value $DurationSeconds
Add-ScenarioMetric -Key "file_operations" -Value $(if ($fileOps) { $fileOps } else { "N/A" })
Add-ScenarioMetric -Key "registry_operations" -Value $(if ($regOps) { $regOps } else { "N/A" })
Add-ScenarioMetric -Key "network_requests" -Value $(if ($netReqs) { $netReqs } else { "N/A" })
Add-ScenarioMetric -Key "expected_event_types" -Value "PROCESS_*, FILE_*, REGISTRY_*, NETWORK_*, DNS_QUERY, MODULE_LOADED (10+ types)"
Add-ScenarioMetric -Key "estimated_total_events" -Value "3000-10000"

# Cleanup
Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue

Complete-Scenario
