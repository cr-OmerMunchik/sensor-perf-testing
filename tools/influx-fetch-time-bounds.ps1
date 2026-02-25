# Run on MON VM. Outputs JSON with from/to per scenario.
param([string]$Token = $env:INFLUXDB_TOKEN)
$url = "http://localhost:8086/api/v2/query?org=activeprobe-perf"
$h = @{ "Authorization" = "Token $Token"; "Accept" = "application/csv"; "Content-Type" = "application/vnd.flux" }

$scenarios = @("user_account_modify", "combined_high_density", "registry_storm", "process_storm")
$out = @()

foreach ($sc in $scenarios) {
    $firstQ = "from(bucket: `"telegraf`") |> range(start: -14d) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> filter(fn: (r) => r.scenario == `"$sc`") |> filter(fn: (r) => r.host == `"TEST-PERF-3`") |> first()"
    $lastQ = "from(bucket: `"telegraf`") |> range(start: -14d) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> filter(fn: (r) => r.scenario == `"$sc`") |> filter(fn: (r) => r.host == `"TEST-PERF-3`") |> last()"
    $r1 = (Invoke-WebRequest -Uri $url -Method Post -Headers $h -Body $firstQ -ContentType "application/vnd.flux" -UseBasicParsing).Content
    $r2 = (Invoke-WebRequest -Uri $url -Method Post -Headers $h -Body $lastQ -ContentType "application/vnd.flux" -UseBasicParsing).Content
    $from = $null; $to = $null
    foreach ($line in ($r1 -split "`n")) {
        if ($line -match ",first,\d+,") {
            $p = $line -split ","
            if ($p.Count -ge 6 -and $p[5] -match "^\d{4}-\d{2}-\d{2}T") { $from = $p[5]; break }
        }
    }
    foreach ($line in ($r2 -split "`n")) {
        if ($line -match ",last,\d+,") {
            $p = $line -split ","
            if ($p.Count -ge 6 -and $p[5] -match "^\d{4}-\d{2}-\d{2}T") { $to = $p[5]; break }
        }
    }
    if ($from -and $to) { $out += [PSCustomObject]@{ scenario = $sc; from = $from; to = $to } }
}

$out | ConvertTo-Json -Depth 3
