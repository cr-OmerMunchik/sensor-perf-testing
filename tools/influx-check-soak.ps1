# Check if soak_test data exists for Feb 21 time range
param([string]$Token = $env:INFLUXDB_TOKEN, [string]$InfluxUrl = "http://localhost:8086")
$url = "$InfluxUrl/api/v2/query?org=activeprobe-perf"
$headers = @{ "Authorization" = "Token $Token"; "Accept" = "application/csv"; "Content-Type" = "application/vnd.flux" }

Write-Host "`n=== soak_test in 2026-02-21 13:50-14:15 UTC ===" -ForegroundColor Cyan
$q = @'
from(bucket: "telegraf")
  |> range(start: 2026-02-21T13:50:00Z, stop: 2026-02-21T14:15:00Z)
  |> filter(fn: (r) => r.scenario == "soak_test")
  |> filter(fn: (r) => r.host == "TEST-PERF-3" or r.host == "TEST-PERF-4")
  |> limit(n: 5)
  |> keep(columns: ["_time", "host", "_measurement", "scenario"])
'@
try {
    $r = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $q -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 10
    $lines = $r.Content -split "`n" | Where-Object { $_ -notmatch "^#" -and $_ -match "\d{4}-\d{2}-\d{2}T" }
    if ($lines.Count -gt 0) { $lines | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no data)" -ForegroundColor Yellow }
} catch { Write-Host "  Error: $_" -ForegroundColor Red }

Write-Host "`n=== Earliest data in telegraf bucket ===" -ForegroundColor Cyan
$q2 = @'
from(bucket: "telegraf")
  |> range(start: -30d)
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> first()
  |> keep(columns: ["_time", "host", "scenario"])
'@
try {
    $r2 = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $q2 -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 10
    $lines = $r2.Content -split "`n" | Where-Object { $_ -notmatch "^#" -and $_ -match "\d{4}-\d{2}-\d{2}T" }
    if ($lines.Count -gt 0) { $lines | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no data in 30d)" -ForegroundColor Yellow }
} catch { Write-Host "  Error: $_" -ForegroundColor Red }

Write-Host "`n=== Any soak_test data (last 30d) ===" -ForegroundColor Cyan
$q3 = @'
from(bucket: "telegraf")
  |> range(start: -30d)
  |> filter(fn: (r) => r.scenario == "soak_test")
  |> limit(n: 3)
  |> keep(columns: ["_time", "host", "scenario"])
'@
try {
    $r3 = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $q3 -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 10
    $lines = $r3.Content -split "`n" | Where-Object { $_ -notmatch "^#" -and $_ -match "\d{4}-\d{2}-\d{2}T" }
    if ($lines.Count -gt 0) { $lines | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no soak_test data in 30d)" -ForegroundColor Yellow }
} catch { Write-Host "  Error: $_" -ForegroundColor Red }
