<#
.SYNOPSIS
    Queries InfluxDB for first/last timestamps per scenario. Outputs JSON for building exact Grafana links.
#>
param(
    [string]$Token = $env:INFLUXDB_TOKEN,
    [string]$InfluxUrl = "http://localhost:8086",
    [string]$TimeRange = "-14d",
    [string]$OutputPath = "",
    [string[]]$Scenarios = @("user_account_modify", "combined_high_density", "registry_storm", "process_storm")
)

$ErrorActionPreference = "Stop"
if (-not $Token) { Write-Error "INFLUXDB_TOKEN required" }
$debugLog = @()

$queryUrl = "$InfluxUrl/api/v2/query?org=activeprobe-perf"
$headers = @{ "Authorization" = "Token $Token"; "Accept" = "application/csv"; "Content-Type" = "application/vnd.flux" }

function Invoke-Flux { param([string]$Q)
    try {
        $r = Invoke-WebRequest -Uri $queryUrl -Method Post -Headers $headers -Body $Q -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 30
        return $r.Content
    } catch { return $null }
}

function Parse-TimeFromCsv {
    param([string]$csv)
    foreach ($line in ($csv -split "`n")) {
        if ($line -notmatch "^#" -and $line -match "_result,\d+,") {
            $parts = $line -split ","
            if ($parts.Count -ge 6 -and $parts[5] -match "^\d{4}-\d{2}-\d{2}T") {
                return $parts[5].Trim()
            }
        }
    }
    return $null
}

$results = @()
foreach ($sc in $Scenarios) {
    $esc = $sc -replace '"', '\"'
    $firstQ = "from(bucket: `"telegraf`") |> range(start: $TimeRange) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> filter(fn: (r) => r.scenario == `"$esc`") |> filter(fn: (r) => r.host == `"TEST-PERF-3`") |> first() |> yield(name: `"first`")"
    $lastQ = "from(bucket: `"telegraf`") |> range(start: $TimeRange) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> filter(fn: (r) => r.scenario == `"$esc`") |> filter(fn: (r) => r.host == `"TEST-PERF-3`") |> last() |> yield(name: `"last`")"
    $firstCsv = Invoke-Flux $firstQ
    $lastCsv = Invoke-Flux $lastQ
    $firstTime = Parse-TimeFromCsv $firstCsv
    $lastTime = Parse-TimeFromCsv $lastCsv
    if ($firstTime -and $lastTime) {
        $results += [PSCustomObject]@{ scenario = $sc; from = $firstTime; to = $lastTime }
    }
}

$json = $results | ConvertTo-Json -Depth 3
Write-Output $json
if ($OutputPath) { $json | Set-Content -Path $OutputPath -Encoding UTF8 }
