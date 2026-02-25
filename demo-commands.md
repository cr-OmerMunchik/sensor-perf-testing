# Demo Command-Line Examples

Quick reference for running tests, generating reports, and analyzing traces.

**Where to run:** Tests run on the **test VMs** (TEST-PERF-3, TEST-PERF-4). Report generation and trace collection run on your **workstation** (from the `sensor-perf-testing` repo root unless noted).

---

## Running Tests (on test VMs)

Copy `test-scenarios/` to each test VM, then run:

```powershell
cd C:\PerfTest\test-scenarios   # or wherever you copied it

# Run all scenarios (~3–4 hours)
.\Run-AllScenarios.ps1

# Run specific scenarios only
.\Run-AllScenarios.ps1 -OnlyScenarios @("user_account_modify", "combined_high_density")

# Run with WPR profiling (captures .etl traces to C:\PerfTest\traces\)
.\Run-AllScenarios.ps1 -EnableProfiling -OnlyScenarios @("user_account_modify", "combined_high_density")

# Shorter pauses between scenarios (30s instead of 60s)
.\Run-AllScenarios.ps1 -PauseBetweenSeconds 30

# Skip scenarios that need special setup
.\Run-AllScenarios.ps1 -SkipScenarios @("browser_streaming", "driver_load")
```

---

## Collecting Traces (from workstation)

```powershell
cd sensor-perf-testing

# Collect .etl files from test VMs to local (default: C:\PerfTest\collected-traces\<date>)
.\test-scenarios\Collect-Traces.ps1

# Collect to custom directory
.\test-scenarios\Collect-Traces.ps1 -LocalDir "C:\Users\OmerMunchik\playground\traces\2026-02-24"

# Collect from specific VM only, then delete traces on VM
.\test-scenarios\Collect-Traces.ps1 -VMs @("172.46.16.176") -Cleanup
```

---

## InfluxDB (on MON VM or workstation)

```powershell
$env:INFLUXDB_TOKEN = "your-token"

# Option A: Run on MON VM (copy tools/influx-analyze.ps1 first)
.\influx-analyze.ps1 -InfluxUrl http://localhost:8086 -OutputPath C:\temp\influx-data.json

# Option B: Fetch from workstation if InfluxDB is reachable
.\tools\influx-analyze.ps1 -InfluxUrl http://172.46.16.24:8086 -OutputPath influx-data.json -TimeRange "-7d"

# Option C: SSH to MON, run influx-analyze, SCP JSON back (recommended when workstation can't reach InfluxDB)
.\tools\run-influx-on-mon.ps1
# → Creates influx-data-fresh.json in repo root
```

---

## Generating Reports (from sensor-perf-testing repo root)

```powershell
# Full report: InfluxDB + ETL traces (~30–60 min)
$env:INFLUXDB_TOKEN = "your-token"
.\tools\generate-perf-report.ps1 -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23"

# ETL only (skip InfluxDB)
.\tools\generate-perf-report.ps1 -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23" -SkipInfluxDB

# With symbols for readable function names
.\tools\generate-perf-report.ps1 -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23" -UseSymbols -SkipInfluxDB

# Quick test: only 2 traces
.\tools\generate-perf-report.ps1 -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23" -SkipInfluxDB -TraceLimit 2

# Use pre-fetched InfluxDB JSON (when MON VM unreachable)
.\tools\generate-perf-report.ps1 -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23" -InfluxJsonPath ".\influx-data-fresh.json"
```

---

## Executive Summary (VP-ready one-pager)

```powershell
.\tools\generate-executive-summary.ps1 -InfluxJsonPath ".\influx-data-fresh.json" -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23" -Scenario user_account_modify
```

---

## ETL Analyzer (standalone)

```powershell
cd sensor-perf-testing

# Process traces, no symbols (faster)
dotnet run --project tools/etl-analyzer -- "C:\Users\OmerMunchik\playground\traces\2026-02-23"

# With symbols (readable function names like TrayKeepAliveTask::handler)
dotnet run --project tools/etl-analyzer -- "C:\Users\OmerMunchik\playground\traces\2026-02-23" --symbols

# Only user_account_modify traces
dotnet run --project tools/etl-analyzer -- "C:\Users\OmerMunchik\playground\traces\2026-02-23" --scenario user_account_modify --symbols

# Limit to first 2 traces (quick smoke test)
dotnet run --project tools/etl-analyzer -- "C:\Users\OmerMunchik\playground\traces\2026-02-23" --limit 2
```

---

## Diagnostics

```powershell
# InfluxDB: list buckets, measurements, sample data (run on MON VM or from workstation if reachable)
$env:INFLUXDB_TOKEN = "your-token"
.\tools\influx-diagnose.ps1 -InfluxUrl http://localhost:8086 -TimeRange "-7d"

# Verify InfluxDB reachability from workstation
Test-NetConnection 172.46.16.24 -Port 8086
```

---

## Output Locations

| Output | Path |
|--------|------|
| Perf report | `sensor-perf-testing/perf-bottleneck-report-YYYYMMDD.md` |
| Executive summary | `sensor-perf-testing/executive-summary-YYYYMMDD.md` |
| InfluxDB JSON | `sensor-perf-testing/influx-data-fresh.json` (from run-influx-on-mon) |
| Collected traces | `C:\PerfTest\collected-traces\<date>\` or custom `-LocalDir` |
