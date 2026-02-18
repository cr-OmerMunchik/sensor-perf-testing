<#
.SYNOPSIS
    Scenario 1: Browser Streaming Session (High Event Density)

.DESCRIPTION
    Opens Edge browser, navigates to a URL, streams for a set duration, then closes.
    Generates: PROCESS_CREATED, PROCESS_ENDED, MODULE_LOADED, NETWORK_*,
    DNS_QUERY, FILE_CREATED, FILE_DELETED

    Estimated yield: 8+ event types, very high density.

.PARAMETER Url
    URL to navigate to. Default: https://www.youtube.com/watch?v=dQw4w9WgXcQ

.PARAMETER DurationSeconds
    How long to stream before closing. Default: 300 (5 minutes).

.PARAMETER Browser
    Browser to use. Default: msedge. Alternative: chrome.

.EXAMPLE
    .\Test-BrowserStreaming.ps1
    .\Test-BrowserStreaming.ps1 -DurationSeconds 600 -Browser "chrome"
#>

param(
    [string]$Url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    [int]$DurationSeconds = 300,
    [string]$Browser = "msedge"
)

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "browser_streaming" `
    -Description "Browser streaming session ($Browser, ${DurationSeconds}s)"

$browserProcess = "$Browser.exe"

$browserPath = Get-Command $browserProcess -ErrorAction SilentlyContinue
if (-not $browserPath) {
    Write-Host "[SKIP] $browserProcess not found on this system. Skipping browser streaming." -ForegroundColor Yellow
    Add-ScenarioMetric -Key "skipped" -Value $true
    Add-ScenarioMetric -Key "reason" -Value "$browserProcess not installed"
    Complete-Scenario
    return
}

Write-Host "Launching $browserProcess -> $Url" -ForegroundColor White
$proc = Start-Process $browserProcess -ArgumentList $Url -PassThru

Add-ScenarioMetric -Key "browser" -Value $Browser
Add-ScenarioMetric -Key "url" -Value $Url
Add-ScenarioMetric -Key "stream_duration_seconds" -Value $DurationSeconds

Write-Host "Streaming for $DurationSeconds seconds..." -ForegroundColor Gray
for ($i = 0; $i -lt $DurationSeconds; $i += 30) {
    $remaining = $DurationSeconds - $i
    Write-Progress -Activity "Browser Streaming" `
        -Status "$remaining seconds remaining" `
        -PercentComplete (($i / $DurationSeconds) * 100)
    Start-Sleep -Seconds ([math]::Min(30, $remaining))
}
Write-Progress -Activity "Browser Streaming" -Completed

Write-Host "Closing $browserProcess..." -ForegroundColor White
Stop-Process -Name $Browser -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$browserProcs = Get-Process -Name $Browser -ErrorAction SilentlyContinue
if ($browserProcs) {
    $browserProcs | Stop-Process -Force -ErrorAction SilentlyContinue
}

Add-ScenarioMetric -Key "expected_events" -Value "PROCESS_CREATED, PROCESS_ENDED, MODULE_LOADED, NETWORK_*, DNS_QUERY, FILE_CREATED, FILE_DELETED"
Add-ScenarioMetric -Key "estimated_total_events" -Value "700-3500"

Complete-Scenario
