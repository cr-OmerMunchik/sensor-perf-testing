# Grafana "No Data" Root Cause

## Summary

**Root cause:** Telegraf on the test VMs stopped sending data to InfluxDB around **09:00–09:01 UTC**. The most recent data points in InfluxDB are from that time. When you select "Last 5 minutes" or "Last 15 minutes", there is no data because nothing has been written since ~09:01 UTC.

## Evidence

| Query | Result |
|-------|--------|
| Last 5 minutes (win_cpu) | No data |
| Last 15 minutes (win_cpu) | No data |
| Last 6 hours (win_cpu) | ~1,571 points per field |
| **Latest _time in data** | **2026-02-25T09:00:40Z** (TEST-PERF-1), **09:01:10Z** (TEST-PERF-2) |
| Server time (InfluxDB host) | 02/25/2026 12:38 UTC+2 ≈ 10:38 UTC |

The data stopped flowing **~1.5 hours** before the diagnostic run. "Last 6 hours" shows data because the 6-hour window includes the period when Telegraf was still writing (04:38–09:01 UTC).

## Why "Last 6 hours" works but "Last 5 minutes" doesn't

- **Last 6 hours:** The time range includes 04:38–10:38 UTC. Data exists from 04:38–09:01 UTC, so the query returns results.
- **Last 5 minutes:** The time range is 10:33–10:38 UTC. No data was written in that window, so the query returns nothing.

## Fix

### If data stopped (Telegraf not writing)

1. **Check token** – Telegraf config must have `token = "YOUR_TOKEN"` without extra quotes. If you see `token = "'YOUR_TOKEN'"`, run:
   ```powershell
   .\tools\Fix-TelegrafToken.ps1
   ```

2. **Restart Telegraf** on all test VMs:
   ```powershell
   # On each test VM (172.46.16.37, 172.46.17.49, 172.46.16.176, 172.46.21.24):
   Restart-Service Telegraf
   ```

2. **Verify** data is flowing again:
   ```powershell
   .\tools\run-influx-check-on-mon.ps1
   ```
   You should see data in "Last 5 minutes" within 1–2 minutes after restart.

3. **Check Telegraf logs** if the problem recurs:
   ```powershell
   ssh admin@172.46.16.37 "Get-Content C:\Program Files\Telegraf\telegraf.log -Tail 50"
   ```

## Possible causes of Telegraf stopping

- **Invalid token** – Token in `telegraf.conf` had extra single quotes (`token = "'TOKEN'"`), causing InfluxDB to reject writes. Fixed by `Fix-TelegrafToken.ps1` and `Deploy-TelegrafToAllVMs.ps1`.
- Telegraf process crashed or was stopped
- Network connectivity to InfluxDB (172.46.16.24:8086) was lost
- InfluxDB write failures (rate limit, or disk)
- VM reboot or sleep

## Grafana shows "No data" for historical links (e.g. soak_test Feb 21)

**Cause:** The Sensor Version variable did not include empty string `""`. Older data (e.g. from Feb 21) often has `sensor_version=""`. With "All" selected, the variable regex did not match empty, so all rows were filtered out.

**Fix:** The dashboard now includes `""` in the sensor_version variable options. Re-import the dashboard to Grafana:
```powershell
.\tools\Import-GrafanaDashboard.ps1 -BackupFirst
```

## Diagnostic script

Use `tools\influx-check-recent.ps1` (run via `tools\run-influx-check-on-mon.ps1`) to quickly verify whether recent data exists in InfluxDB.
