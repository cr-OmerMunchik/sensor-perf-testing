# Performance Bottleneck Analysis Tools

Automated tools for analyzing InfluxDB metrics and ETL trace files to identify ActiveProbe sensor performance bottlenecks.

## Quick Start

**Executive summary (VP-ready, one scenario, ~5 min):**
```powershell
.\tools\generate-executive-summary.ps1 -InfluxJsonPath ".\influx-data-fresh.json" -TraceDir "C:\path\to\traces"
```
Picks the scenario where **sensor processes** (minionhost, ActiveConsole) dominate the trace—not the test harness. Compares VM3 vs VM4, shows top processes (sensor marked) and bottleneck functions with symbols.

**Full report (all scenarios, ~30-60 min):**

**From the `sensor-perf-testing` repo root:**

```powershell
# Option A: Full run (InfluxDB + all ETL traces, ~30-60 min)
$env:INFLUXDB_TOKEN = "your-token"
.\tools\generate-perf-report.ps1 -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23"

# Option B: InfluxDB unreachable from workstation? Run on MON VM, then use JSON
#   On MON VM: .\influx-analyze.ps1 -InfluxUrl http://localhost:8086 -OutputPath C:\temp\influx-data.json
#   Copy influx-data.json to workstation, then:
.\tools\generate-perf-report.ps1 -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23" -InfluxJsonPath "C:\temp\influx-data.json"

# Option C: Skip InfluxDB entirely (ETL only)
.\tools\generate-perf-report.ps1 -SkipInfluxDB -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23"

# Option D: Quick test (~5-10 min): skip InfluxDB, process only 2 traces
.\tools\generate-perf-report.ps1 -SkipInfluxDB -TraceLimit 2

# Report is written to sensor-perf-testing/perf-bottleneck-report-YYYYMMDD.md
```

## Components

| Script / Tool | Purpose |
|---------------|---------|
| `influx-analyze.ps1` | Queries InfluxDB for sensor CPU, memory, KPI failures, sensor vs no-sensor deltas |
| `influx-diagnose.ps1` | Diagnoses empty InfluxDB output: lists buckets, measurements, sample data |
| `etl-analyzer/` | C# tool that processes .etl files and extracts top processes/functions by CPU |
| `generate-perf-report.ps1` | Orchestrator: runs both, merges findings, produces Markdown report |

## Usage

### InfluxDB Analysis (standalone)

```powershell
$env:INFLUXDB_TOKEN = "your-token"
.\influx-analyze.ps1 -OutputPath "influx-findings.json"
.\influx-analyze.ps1 -TimeRange "-30d"  # Last 30 days
```

### ETL Analyzer (standalone)

```powershell
# Without symbols (faster, module+offset only)
dotnet run --project etl-analyzer -- "C:\path\to\traces"

# With symbols (slower, requires network to symbol server)
dotnet run --project etl-analyzer -- "C:\path\to\traces" --symbols
```

### Full Report

```powershell
.\generate-perf-report.ps1 `
  -TraceDir "C:\Users\OmerMunchik\playground\traces\2026-02-23" `
  -OutputPath "my-report.md" `
  -UseSymbols  # Optional: resolve function names
```

## Prerequisites

- **InfluxDB token**: Created during MON VM setup; not stored in repo
- **.NET 8 SDK**: For building/running EtlAnalyzer
- **Trace files**: .etl files from WPR (see `docs/profiling-guide.md`)

## Troubleshooting

**Empty InfluxDB output (all arrays empty):**  
Run the diagnostic script on MON VM to discover the actual schema:
```powershell
.\influx-diagnose.ps1 -InfluxUrl http://localhost:8086
```
This shows buckets, measurements, sample data, and tag values. Common causes: wrong bucket/org, no data in `-7d` (try `-TimeRange -30d`), or Telegraf not running on test VMs.

**System CPU / System memory show N/A in report:**  
InfluxDB win_cpu/win_mem parsing may be wrong. On MON VM, run with debug dump to inspect raw CSV:
```powershell
.\influx-analyze.ps1 -InfluxUrl http://localhost:8086 -OutputPath C:\temp\influx-data.json -DebugDumpCsv
# Or: .\influx-dump-raw.ps1 -InfluxUrl http://localhost:8086 -OutDir .
```
Check `influx-raw-win_cpu.csv` and `influx-raw-win_mem.csv` for column layout and `_value` position.

**"Unable to connect to the remote server" (InfluxDB):**  
Your workstation cannot reach the MON VM (172.46.16.24:8086). Instead of skipping InfluxDB:

1. **On MON VM** (where InfluxDB runs locally): copy `tools/` there, then run:
   ```powershell
   $env:INFLUXDB_TOKEN = "your-token"
   .\influx-analyze.ps1 -InfluxUrl http://localhost:8086 -OutputPath C:\temp\influx-data.json
   ```
2. Copy `influx-data.json` to your workstation (e.g. SCP, shared folder).
3. Run the report with `-InfluxJsonPath`:
   ```powershell
   .\tools\generate-perf-report.ps1 -TraceDir "C:\path\to\traces" -InfluxJsonPath "C:\temp\influx-data.json"
   ```

**Script takes too long:**  
Use `-TraceLimit 2` to process only the first 2 traces (~5–10 min) for a quick test.

## Output

The report includes:

- Executive summary (top bottlenecks)
- KPI failures (CPU >15%, memory >500 MB)
- CPU, memory, and disk I/O by scenario (top 3 busiest only)
- System overload comparison: with vs without sensor
- Per-trace: top processes, top sensor functions (Module and Function columns)
