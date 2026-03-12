# Quick check: latest timestamps in InfluxDB for last 5m vs last 6h
param(
    [string]$Token = $env:INFLUXDB_TOKEN,
    [string]$InfluxUrl = "http://localhost:8086"
)
$url = "$InfluxUrl/api/v2/query?org=activeprobe-perf"
$headers = @{ "Authorization" = "Token $Token"; "Accept" = "application/csv"; "Content-Type" = "application/vnd.flux" }

Write-Host "`n=== Last 5 minutes (win_cpu) - first 3 points ===" -ForegroundColor Cyan
$q5 = @'
from(bucket: "telegraf")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> limit(n: 3)
  |> keep(columns: ["_time", "host", "_measurement"])
'@
try {
    $r5 = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $q5 -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 10
    $lines = $r5.Content -split "`n"
    $dataLines = $lines | Where-Object { $_ -notmatch "^#" -and $_ -match "\d{4}-\d{2}-\d{2}T" }
    if ($dataLines.Count -gt 0) { $dataLines | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no data in last 5m)" -ForegroundColor Yellow }
} catch { Write-Host "  Error: $_" -ForegroundColor Red }

Write-Host "`n=== Last 15 minutes (win_cpu) - first 3 points ===" -ForegroundColor Cyan
$q15 = @'
from(bucket: "telegraf")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> limit(n: 3)
  |> keep(columns: ["_time", "host"])
'@
try {
    $r15 = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $q15 -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 10
    $lines = $r15.Content -split "`n"
    $dataLines = $lines | Where-Object { $_ -notmatch "^#" -and $_ -match "\d{4}-\d{2}-\d{2}T" }
    if ($dataLines.Count -gt 0) { $dataLines | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no data in last 15m)" -ForegroundColor Yellow }
} catch { Write-Host "  Error: $_" -ForegroundColor Red }

Write-Host "`n=== Last 5 minutes (sensor_process) ===" -ForegroundColor Cyan
$q5s = @'
from(bucket: "telegraf")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "sensor_process")
  |> last()
  |> keep(columns: ["_time", "host"])
'@
try {
    $r5s = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $q5s -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 10
    $lines = $r5s.Content -split "`n"
    $dataLines = $lines | Where-Object { $_ -notmatch "^#" -and $_ -match "\d{4}-\d{2}-\d{2}T" }
    if ($dataLines.Count -gt 0) { $dataLines | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no rows - empty result)" -ForegroundColor Yellow }
} catch { Write-Host "  Error: $_" -ForegroundColor Red }

Write-Host "`n=== Last 6 hours (win_cpu) - count of points ===" -ForegroundColor Cyan
$q6 = @'
from(bucket: "telegraf")
  |> range(start: -6h)
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> count()
'@
try {
    $r6 = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $q6 -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 10
    $lines = $r6.Content -split "`n"
    $dataLines = $lines | Where-Object { $_ -notmatch "^#" -and $_ -match "^\d{4}-|," }
    if ($dataLines.Count -gt 0) { Write-Host "  Rows with count: $($dataLines.Count)"; $dataLines | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no data in 6h)" -ForegroundColor Yellow }
} catch { Write-Host "  Error: $_" -ForegroundColor Red }

Write-Host "`n=== Latest _time in last 6h (win_cpu) ===" -ForegroundColor Cyan
$qmax = @'
from(bucket: "telegraf")
  |> range(start: -6h)
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> last()
  |> keep(columns: ["_time", "host"])
'@
try {
    $rmax = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $qmax -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 10
    $lines = $rmax.Content -split "`n"
    $dataLines = $lines | Where-Object { $_ -notmatch "^#" -and $_ -match "," }
    if ($dataLines.Count -gt 0) { $dataLines | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no data)" -ForegroundColor Yellow }
} catch { Write-Host "  Error: $_" -ForegroundColor Red }

Write-Host "`n=== Latest _time in telegraf bucket (any measurement) ===" -ForegroundColor Cyan
$qlatest = @'
from(bucket: "telegraf")
  |> range(start: -24h)
  |> last()
  |> keep(columns: ["_time", "_measurement", "host"])
  |> sort(columns: ["_time"], desc: true)
  |> limit(n: 5)
'@
try {
    $rlat = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $qlatest -ContentType "application/vnd.flux" -UseBasicParsing -TimeoutSec 10
    $lines = $rlat.Content -split "`n"
    $dataLines = $lines | Where-Object { $_ -notmatch "^#" -and $_ -match "\d{4}-\d{2}-\d{2}T" }
    if ($dataLines.Count -gt 0) { $dataLines | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no data in 24h)" -ForegroundColor Yellow }
} catch { Write-Host "  Error: $_" -ForegroundColor Red }

Write-Host "`n=== Server time (InfluxDB host) ===" -ForegroundColor Cyan
Write-Host "  $(Get-Date)" -ForegroundColor Gray
