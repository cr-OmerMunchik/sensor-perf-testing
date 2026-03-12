$Token = "TXAx5RsDsBxHqCgaGbeKEZWEHprToZUIEuQ5MfCehnhgv8g-0q836nnw9Y3fF5CN8RxIqJtLNqFS2ZCxkv3dQA=="
$url = "http://localhost:8086/api/v2/query?org=activeprobe-perf"
$headers = @{
    "Authorization" = "Token $Token"
    "Accept" = "application/csv"
    "Content-Type" = "application/vnd.flux"
}

$queries = @{
    "win_cpu (all hosts)" = @'
from(bucket: "telegraf") |> range(start: -2m) |> filter(fn: (r) => r._measurement == "win_cpu" and r._field == "Percent_Processor_Time") |> group(columns: ["host"]) |> last() |> keep(columns: ["_time","host","_value"])
'@
    "sensor_liveness" = @'
from(bucket: "telegraf") |> range(start: -2m) |> filter(fn: (r) => r._measurement == "sensor_liveness") |> group(columns: ["host"]) |> last() |> keep(columns: ["_time","host","_field","_value"])
'@
    "sensor_db_size" = @'
from(bucket: "telegraf") |> range(start: -2m) |> filter(fn: (r) => r._measurement == "sensor_db_size") |> group(columns: ["host"]) |> last() |> keep(columns: ["_time","host","_value"])
'@
    "sensor_driver_instances" = @'
from(bucket: "telegraf") |> range(start: -2m) |> filter(fn: (r) => r._measurement == "sensor_driver_instances") |> group(columns: ["host"]) |> last() |> keep(columns: ["_time","host","_value"])
'@
    "system_process" = @'
from(bucket: "telegraf") |> range(start: -2m) |> filter(fn: (r) => r._measurement == "system_process" and r._field == "Percent_Processor_Time") |> group(columns: ["host","instance"]) |> last() |> keep(columns: ["_time","host","instance","_value"])
'@
    "vm_size tag check" = @'
from(bucket: "telegraf") |> range(start: -2m) |> filter(fn: (r) => r._measurement == "win_cpu" and r._field == "Percent_Processor_Time") |> group(columns: ["host","vm_size"]) |> last() |> keep(columns: ["_time","host","vm_size","_value"])
'@
}

foreach ($name in $queries.Keys) {
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -Method POST -Body $queries[$name] -UseBasicParsing -TimeoutSec 10
        $lines = $resp.Content -split "`n" | Where-Object { $_ -match '\d{4}-\d{2}-\d{2}T' }
        if ($lines.Count -gt 0) {
            $lines | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
        } else {
            Write-Host "  (no data)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}
