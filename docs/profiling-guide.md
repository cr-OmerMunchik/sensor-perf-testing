# WPR/WPA Profiling Guide

This guide covers how to capture and analyze WPR (Windows Performance Recorder) traces to identify performance bottlenecks in the ActiveProbe sensor.

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

## Creating Jira Tickets

For each major bottleneck found, create a Jira ticket with the following structure.

### Title format

`[Perf] {Process}: {Brief description}`

Examples:
- `[Perf] minionhost: FileScanner::ScanPath consumes 35% CPU during file operations`
- `[Perf] CrsSvc: Excessive registry polling in EventCollector::PollRegistryChanges`
- `[Perf] ActiveConsole: Memory growth in PhoenixBlockedHashSyncClient during soak test`

### Description template

```
## Scenario
- Test scenario: {e.g., file_storm}
- VM: {e.g., test_perf_3}
- Sensor version: {version}

## Impact
- {Quantified overhead, e.g., "This function accounts for 35% of minionhost.exe CPU during the file_storm scenario"}
- {KPI impact, e.g., "Contributes to total sensor CPU exceeding the 15% under-load target (measured: 22%)"}

## Evidence
- Grafana screenshot: {system-level CPU/memory during the scenario}
- WPA flame graph: {screenshot showing the hot call stack}

## Hot path
{Call stack from WPA, e.g.:}
minionhost.exe!FileScanner::ScanPath
  minionhost.exe!FileScanner::ProcessFileEvent
    minionhost.exe!EventDispatcher::Dispatch
      ntdll.dll!NtQueryDirectoryFile

## Suggested investigation
- {Initial thoughts on why this is hot and potential optimization approaches}

## Reproduction
1. Deploy test scenario scripts to test_perf_3
2. Run: .\Test-FileStorm.ps1 -FileCount 10000 -Bursts 30
3. Capture WPR trace: .\Start-WprTrace.ps1 -Action Start / Stop
4. Open .etl in WPA, filter to minionhost.exe > CPU Usage (Sampled)
```

### Priority classification

| Priority | Criteria | Action |
|----------|----------|--------|
| P1 (Critical) | Function consumes >30% of a sensor process's CPU, or directly causes KPI failure | Fix in current sprint |
| P2 (High) | Function consumes 10-30% of CPU, or measurable latency/memory impact | Schedule for next sprint |
| P3 (Medium) | Function consumes 5-10% of CPU, optimization opportunity | Backlog, address when touching related code |
| P4 (Low) | Minor inefficiency (<5% CPU), no user-visible impact | Backlog, address opportunistically |

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
```
