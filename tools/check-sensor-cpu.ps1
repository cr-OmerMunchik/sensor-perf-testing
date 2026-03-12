$Token = "TXAx5RsDsBxHqCgaGbeKEZWEHprToZUIEuQ5MfCehnhgv8g-0q836nnw9Y3fF5CN8RxIqJtLNqFS2ZCxkv3dQA=="
$url = "http://localhost:8086/api/v2/query?org=activeprobe-perf"
$headers = @{ "Authorization" = "Token $Token"; "Accept" = "application/csv"; "Content-Type" = "application/vnd.flux" }

$q = @'
from(bucket: "telegraf")
  |> range(start: -30m)
  |> filter(fn: (r) => r._measurement == "sensor_process")
  |> filter(fn: (r) => r._field == "Percent_Processor_Time")
  |> filter(fn: (r) => r.host =~ /TEST-PERF-S/)
  |> group(columns: ["host", "instance", "scenario"])
  |> mean()
  |> group()
  |> yield(name: "cpu")
'@

Write-Host "=== Sensor process CPU (last 30m, small VMs) ===" -ForegroundColor Cyan
try {
    $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method POST -Body $q -UseBasicParsing -TimeoutSec 10
    $lines = $resp.Content -split "`n" | Where-Object { $_ -match '\d{4}-\d{2}-\d{2}T' }
    if ($lines.Count -gt 0) { $lines | ForEach-Object { Write-Host "  $_" -ForegroundColor Green } }
    else { Write-Host "  (no data)" -ForegroundColor Yellow }
    Write-Host "`n=== Raw CSV (first 20 lines) ===" -ForegroundColor Cyan
    $resp.Content -split "`n" | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
} catch { Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red }
