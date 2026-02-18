<#
.SYNOPSIS
    Scenario 4: Network Burst via HTTP Requests (Controlled Network Flood)

.DESCRIPTION
    Sends repeated HTTP requests to generate network events.
    Generates: NETWORK_CONNECTION_ATTEMPTED, NETWORK_CONNECTION_ESTABLISHED,
    NETWORK_CONNECTION_CLOSED, DNS_QUERY, PROCESS_CREATED

.PARAMETER RequestCount
    Number of HTTP requests. Default: 200.

.PARAMETER TargetUrl
    URL to request. Default: https://example.com

.PARAMETER RandomSubdomains
    If true, uses random subdomains to force DNS lookups (higher DNS event rate).

.PARAMETER Iterations
    Number of times to repeat. Default: 3.

.EXAMPLE
    .\Test-NetworkBurst.ps1
    .\Test-NetworkBurst.ps1 -RequestCount 500 -RandomSubdomains
#>

param(
    [int]$RequestCount = 200,
    [string]$TargetUrl = "https://example.com",
    [switch]$RandomSubdomains,
    [int]$Iterations = 3
)

. "$PSScriptRoot\ScenarioHelpers.ps1"

Start-Scenario -Name "network_burst" `
    -Description "HTTP request burst (${RequestCount} requests x ${Iterations} iterations)"

$timings = @()
$totalRequests = 0
$totalErrors = 0

for ($iter = 1; $iter -le $Iterations; $iter++) {
    Write-Host "Iteration $iter of $Iterations ($RequestCount requests)..." -ForegroundColor White

    $errors = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    for ($i = 1; $i -le $RequestCount; $i++) {
        try {
            if ($RandomSubdomains) {
                $randomHost = "test-$([guid]::NewGuid().ToString('N').Substring(0,8)).example.com"
                $url = "http://$randomHost"
            }
            else {
                $url = $TargetUrl
            }
            Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop | Out-Null
        }
        catch {
            $errors++
        }

        if ($i % 50 -eq 0) {
            Write-Host "  $i / $RequestCount requests sent..." -ForegroundColor Gray
        }
    }
    $sw.Stop()

    $elapsed = $sw.Elapsed.TotalSeconds
    $rate = [math]::Round($RequestCount / $elapsed, 1)
    $timings += $elapsed
    $totalRequests += $RequestCount
    $totalErrors += $errors

    Write-Host "  $([math]::Round($elapsed, 2))s ($rate req/sec, $errors errors)" -ForegroundColor Green

    if ($iter -lt $Iterations) { Start-Sleep -Seconds 5 }
}

$avgTime = ($timings | Measure-Object -Average).Average

Add-ScenarioMetric -Key "request_count_per_iteration" -Value $RequestCount
Add-ScenarioMetric -Key "iterations" -Value $Iterations
Add-ScenarioMetric -Key "total_requests" -Value $totalRequests
Add-ScenarioMetric -Key "total_errors" -Value $totalErrors
Add-ScenarioMetric -Key "avg_iteration_seconds" -Value ([math]::Round($avgTime, 2))
Add-ScenarioMetric -Key "avg_requests_per_sec" -Value ([math]::Round($RequestCount / $avgTime, 1))
Add-ScenarioMetric -Key "random_subdomains" -Value $RandomSubdomains.IsPresent
Add-ScenarioMetric -Key "expected_events" -Value "NETWORK_CONNECTION_ATTEMPTED, NETWORK_CONNECTION_ESTABLISHED, NETWORK_CONNECTION_CLOSED, DNS_QUERY, PROCESS_CREATED"
Add-ScenarioMetric -Key "estimated_network_events" -Value ($RequestCount * 3)

Complete-Scenario
