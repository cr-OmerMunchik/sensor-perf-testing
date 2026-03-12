# WPR/WPA Profiling Guide

This guide covers how to capture and analyze WPR (Windows Performance Recorder) traces to identify performance bottlenecks in the ActiveProbe sensor.

## Self-Service Profiling (Quick Path)

For most use cases, `Run-PerfTest.ps1` handles profiling end-to-end:

```powershell
.\Run-PerfTest.ps1 -EnableProfiling -SymbolsDir "C:\Symbols\v26.1.30.1"
```

This captures ETL traces per scenario, runs the ETL Analyzer, and generates a function-level CPU hotspot report automatically. See [Self-Service Guide](self-service-guide.md) for setup and PDB symbol instructions.

The rest of this guide covers **advanced and manual WPR/WPA usage** for deeper investigation.

---

## Prerequisites

### On your workstation (for analysis)

1. **Install Windows Performance Toolkit** from the [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install):
   - Download the ADK installer
   - Select only **Windows Performance Toolkit** (you don't need the other components)
   - This gives you `wpa.exe` (Windows Performance Analyzer)

2. **Configure the symbol path** so WPA can resolve sensor function names:
   ```
   setx _NT_SYMBOL_PATH "srv*C:\Symbols*\\172.25.1.155\symbols-releases;srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"
   ```
   - First part: internal symbol server for ActiveProbe PDBs
   - Second part: Microsoft public symbols for OS/kernel functions
   - `C:\Symbols` is a local cache (created automatically)

   > **Tip**: If the internal symbol server is unavailable, you can download PDB files manually from the Jenkins build artifacts. Go to the [integration build page](https://jenkins-irelease.eng.cybereason.net/view/Release-Candidates/view/integration/job/msi-sensor-x64-release-build-integration/), find the matching build, download `output-x64.zip`, and extract it locally. Then set the symbol path to include that directory. See [Self-Service Guide](self-service-guide.md#pdb-symbols-for-function-name-resolution) for details.

### On test VMs (for capture)

WPR is pre-installed on Windows 10/11. Verify by running:
```powershell
wpr.exe -status
```

If missing, install the Windows Performance Toolkit from the Windows ADK on the VM.

---

## Capturing Traces

### Option 1: Integrated with test scenarios (recommended)

Run scenarios with the `-EnableProfiling` flag. A WPR trace is automatically captured for each scenario:

```powershell
# Profile specific scenarios
.\Run-AllScenarios.ps1 -EnableProfiling -OnlyScenarios @("file_storm", "combined_high_density")

# Profile all scenarios (generates ~3-6 GB of traces)
.\Run-AllScenarios.ps1 -EnableProfiling

# Profile with custom WPR profiles (e.g., add heap tracking)
.\Run-AllScenarios.ps1 -EnableProfiling -ProfilingProfiles @("GeneralProfile", "DiskIO", "Heap")
```

Traces are saved to `C:\PerfTest\traces\` on the VM.

### Option 2: Standalone ad-hoc profiling

Use `Start-WprTrace.ps1` to manually control trace recording:

```powershell
# Start a trace
.\Start-WprTrace.ps1 -Action Start

# ... run whatever you want to profile ...

# Stop and save
.\Start-WprTrace.ps1 -Action Stop -ScenarioName "my_investigation"

# Check if a trace is recording
.\Start-WprTrace.ps1 -Action Status

# Cancel without saving
.\Start-WprTrace.ps1 -Action Cancel
```

### WPR Profiles

| Profile | What it captures | Trace size impact | When to use |
|---------|-----------------|-------------------|-------------|
| GeneralProfile | CPU sampling, context switches, basic I/O | ~200-300 MB / 10 min | Default, good all-around |
| DiskIO | Physical/logical disk operations | ~50-100 MB / 10 min | Disk bottleneck investigation |
| FileIO | File create/open/read/write/delete | ~100-200 MB / 10 min | File access pattern analysis |
| CPU | CPU sampling with call stacks | ~100-200 MB / 10 min | Focused CPU analysis |
| Heap | Memory allocations with call stacks | ~500 MB+ / 10 min | Memory leak investigation (high overhead) |
| Network | TCP/UDP activity | ~50-100 MB / 10 min | Network overhead analysis |

---

## Collecting Traces

After running scenarios with profiling, collect the `.etl` files from the VMs to your workstation:

```powershell
# From your workstation -- collects from both VM3 and VM4
.\Collect-Traces.ps1

# Collect from VM3 only and clean up remote files
.\Collect-Traces.ps1 -VMs @("172.46.16.176") -Cleanup

# Collect to a custom directory
.\Collect-Traces.ps1 -LocalDir "D:\my-traces"
```

Traces are organized by date: `C:\PerfTest\collected-traces\2026-02-22\*.etl`

---

## Analyzing Traces in WPA

### Opening a trace

1. Launch WPA (`wpa.exe`)
2. File > Open > select the `.etl` file
3. Configure symbols: Trace > Configure Symbol Paths > verify `_NT_SYMBOL_PATH` is set
4. Load symbols: Trace > Load Symbols (this may take 30-60 seconds the first time)

### Key analysis views

#### 1. CPU Usage (Sampled) -- "Where is CPU time spent?"

- In the Graph Explorer panel, expand **Computation** > drag **CPU Usage (Sampled)** to the analysis area
- Group by: **Process** > **Module** > **Function** (in the column headers)
- Filter to sensor processes: right-click Process column > Filter To Selection > select `minionhost.exe`, `ActiveConsole.exe`, `CrsSvc.exe`, etc.
- Sort by **Weight %** descending to see the hottest functions
- Use the **Flame Graph** view (icon in the toolbar) for a visual call-stack breakdown

**What to look for:**
- Functions consuming >5% of a sensor process's CPU
- Unexpected OS API calls dominating (e.g., heavy `NtQueryDirectoryFile` = excessive directory scanning)
- Deep call stacks indicating recursive or repetitive operations

#### 2. Disk I/O -- "What is the sensor reading/writing?"

- Graph Explorer > **Storage** > **Disk Usage**
- Group by: **Process** > **IO Type** (Read/Write) > **Path**
- Filter to sensor processes
- Sort by **Size** or **Count**

**What to look for:**
- Sensor processes doing unexpected disk I/O
- High read counts on specific files (config re-reads, log scanning)
- Write bursts (excessive logging, temp files)

#### 3. File I/O -- "What files is the sensor accessing?"

- Graph Explorer > **Storage** > **File I/O**
- Group by: **Process** > **File Path**
- This shows higher-level file operations (create, open, close, rename, delete)

**What to look for:**
- Sensor scanning directories it shouldn't need to
- Repeated opens/closes of the same file
- Operations on irrelevant file types

#### 4. CPU Usage (Precise) / Wait Analysis -- "Where are threads blocked?"

- Graph Explorer > **Computation** > **CPU Usage (Precise)**
- Group by: **New Process** > **New Thread** > **Readying Process**
- Shows what each thread was waiting on before being scheduled

**What to look for:**
- Long wait times on locks (contention between sensor threads)
- Threads blocked on I/O completion
- High context switch rates

### Workflow for each scenario

1. Open the `.etl` file for the scenario (e.g., `file_storm_TEST-PERF-3_20260222_143000.etl`)
2. Load symbols
3. Start with **CPU Usage (Sampled)** — filter to sensor processes, find the top 3-5 functions by weight
4. Check **Disk I/O** — is the sensor doing unexpected I/O during this scenario?
5. If a function looks suspicious, right-click > **View Callers** to see the full call chain
6. Take screenshots of findings (WPA > right-click graph > Copy to Clipboard)

---

## ETL Analyzer (Automated Analysis)

The **ETL Analyzer** is a C# tool that processes `.etl` files and extracts top processes and functions by CPU. Use it when you want automated reports without opening WPA, or when integrating into CI pipelines.

### When to use

- **Automated reports** — `generate-perf-report.ps1` and `generate-executive-summary.ps1` use it internally
- **Batch analysis** — Process many traces at once
- **No GUI** — Run from the command line or scripts

### Prerequisites

- **.NET 8 SDK** — Required to build and run the tool

### Usage

From the `sensor-perf-testing` repo root:

```powershell
# Process traces (no symbols — faster, module+offset only)
dotnet run --project tools/etl-analyzer -- "C:\PerfTest\collected-traces\2026-02-22"

# With symbols (readable function names like TrayKeepAliveTask::handler)
dotnet run --project tools/etl-analyzer -- "C:\PerfTest\collected-traces\2026-02-22" --symbols

# Filter by scenario
dotnet run --project tools/etl-analyzer -- "C:\path\to\traces" --scenario user_account_modify --symbols

# Quick smoke test (limit to first 2 traces)
dotnet run --project tools/etl-analyzer -- "C:\path\to\traces" --limit 2
```

### Integration with reports

The ETL Analyzer is used by:

- **`generate-perf-report.ps1`** — Full report: InfluxDB metrics + ETL hotspots merged into Markdown
- **`generate-executive-summary.ps1`** — VP-ready one-pager for a single scenario

See [tools/README.md](../tools/README.md) for the full report workflow.

### Automated vs manual

| Approach | Best for |
|---------|----------|
| **WPA** | Interactive exploration, flame graphs, disk I/O views, ad-hoc investigation |
| **ETL Analyzer** | Automated reports, batch processing, CI, reproducible outputs |

---

## Quick Reference

```powershell
# --- On the test VM ---

# Run scenarios with profiling
.\Run-AllScenarios.ps1 -EnableProfiling -OnlyScenarios @("file_storm")

# Ad-hoc profiling
.\Start-WprTrace.ps1 -Action Start
# ... do something ...
.\Start-WprTrace.ps1 -Action Stop -ScenarioName "investigation_name"

# Check trace files
Get-ChildItem C:\PerfTest\traces\*.etl | Format-Table Name, @{N="Size(MB)";E={[math]::Round($_.Length/1MB,1)}}, LastWriteTime

# --- On your workstation ---

# Collect traces
.\Collect-Traces.ps1

# Set symbol path (one-time)
setx _NT_SYMBOL_PATH "srv*C:\Symbols*\\172.25.1.155\symbols-releases;srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"

# Open trace in WPA
wpa.exe "C:\PerfTest\collected-traces\2026-02-22\file_storm_TEST-PERF-3_20260222_143000.etl"

# ETL Analyzer (automated)
dotnet run --project tools/etl-analyzer -- "C:\PerfTest\collected-traces\2026-02-22" --symbols
```
