# Self-Service Performance & Profiling Guide

Run sensor performance tests and generate reports on **any Windows VM or machine**.

> **Important**: Unless stated otherwise, all commands and installations in this guide should be run **on the target test machine** (the VM or workstation where the sensor is installed), not on your development machine.

---

## Prerequisites

All prerequisites must be installed **on the target machine**.

| Requirement | Details |
|---|---|
| **OS** | Windows 10/11 or Windows Server 2016+ |
| **PowerShell** | 5.1+ (built-in) -- must be run as **Administrator** (right-click PowerShell > "Run as administrator") |
| **CPU cores** | 2+ (2-core VMs use Light mode by default) |
| **Disk space** | 2 GB free minimum; 10+ GB recommended if using `-EnableProfiling` (ETL traces are 200-500 MB each) |
| **.NET SDK** | 8.0+ -- only needed if you enable ETL profiling |
| **wpr.exe** | Windows Performance Toolkit -- only needed for ETL profiling |
| **Sensor installed** | The Cybereason sensor must be running on the test machine |

### Installing .NET SDK (required for ETL profiling)

Install **on the target machine**. The ETL Analyzer is a .NET application that needs the .NET 8 SDK.

```powershell
# Option 1: Install via winget
winget install Microsoft.DotNet.SDK.8

# Option 2: Download manually from
# https://dotnet.microsoft.com/download/dotnet/8.0
# Run the installer and follow the prompts.

# Verify installation
dotnet --version
```

### Installing Windows Performance Toolkit (required for ETL profiling)

Install **on the target machine**.

```powershell
# Download Windows ADK from:
# https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
# During install, select only "Windows Performance Toolkit"
```

Verify: `wpr.exe -status` should return without error.

---

## Quick Start

### 1. Set up the target machine

**Enable SSH Server** (needed if you want to manage the VM remotely from your workstation):

```powershell
# Run on the target VM in an elevated PowerShell
# (right-click PowerShell > "Run as administrator")
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
New-NetFirewallRule -Name "OpenSSH-Server" -DisplayName "OpenSSH Server (sshd)" `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue
```

**Install Git** (on your workstation, if not already installed):

```powershell
winget install Git.Git
```

### 2. Get the test framework

Clone the repo **on your workstation** and copy it to the target machine via SCP:

```powershell
# On your workstation
git clone https://github.com/cr-OmerMunchik/sensor-perf-testing.git
scp -r .\sensor-perf-testing admin@TARGET_VM:C:\sensor-perf-testing
```

Replace `TARGET_VM` with the IP or hostname of your target machine, and `admin` with the username.

### 3. Run the tests

Open an **elevated PowerShell** on the target machine (right-click PowerShell > **"Run as administrator"**) and run:

```powershell
cd C:\sensor-perf-testing

# Default run -- Light mode (~45 min, suitable for any machine)
.\Run-PerfTest.ps1

# Heavy mode -- full workloads (4+ cores recommended, ~3 hours)
.\Run-PerfTest.ps1 -HeavyMode

# With ETL profiling (adds ~200-500 MB per scenario in traces)
.\Run-PerfTest.ps1 -EnableProfiling

# With profiling + PDB symbols for function name resolution
.\Run-PerfTest.ps1 -EnableProfiling -SymbolsDir "C:\Symbols\v26.1.30.1"

# Specific scenarios only
.\Run-PerfTest.ps1 -OnlyScenarios @("file_stress_loop","process_storm","idle_baseline")
```

### 4. Collect reports

Reports are saved to `C:\PerfTest\reports\` on the target machine:

| File | Description |
|---|---|
| `sensor-perf-report-YYYY-MM-DD.html` | Performance report (CPU, memory per process/scenario) |
| `etl-cpu-hotspots-report-YYYY-MM-DD.html` | ETL CPU profiling report (if `-EnableProfiling` was used) |
| `*.confluence.html` | Confluence-compatible versions (if `-GenerateConfluence` was used) |

---

## Light Mode vs Heavy Mode

| | Light Mode (default) | Heavy Mode (`-HeavyMode`) |
|---|---|---|
| **Workload intensity** | Reduced iterations/counts | Full iterations/counts |
| **Per-scenario duration** | ~2-5 min | ~7-15 min |
| **Total suite duration** | ~45 min | ~3 hours |
| **Pause between scenarios** | 30 sec | 60 sec |
| **Recommended cores** | 2+ | 4+ |
| **Use case** | Quick regression check, small VMs | Thorough analysis, production-like load |

Light mode runs the same scenarios with smaller parameters (fewer files, fewer iterations, shorter durations) to keep total runtime manageable and avoid overloading small VMs.

---

## What Gets Measured

### Performance Report (always generated)

Metrics are collected every 5 seconds via Windows Performance Counters during each scenario:

- **Per-process CPU %** -- average and peak for every sensor process (minionhost, ActiveConsole, CrsSvc, Nnx, AmSvc, etc.)
- **Per-process memory** -- working set in MB (average and peak)
- **System CPU %** -- total system CPU utilization
- **Total sensor CPU %** -- sum of all sensor process CPU usage
- **Scenario duration** -- wall-clock time for each scenario

### ETL Profiling Report (with `-EnableProfiling`)

Deep CPU analysis from ETL traces:

- **Process-level CPU breakdown** -- which processes consumed the most CPU samples
- **Function-level hotspots** -- top CPU-consuming functions within sensor modules, resolved from PDB symbols
- **Module attribution** -- which DLL/module each function belongs to
- **Cross-scenario aggregation** -- unified view across all tested workload types

---

## Available Scenarios

| Scenario | Description | Light Mode Duration |
|---|---|---|
| `idle_baseline` | No workload -- measures resting CPU/memory | ~5 min |
| `file_stress_loop` | File create/rename/delete loop | ~3 min |
| `file_storm` | Mass file create/modify/delete bursts | ~3 min |
| `registry_storm` | Registry key set/delete storm | ~2 min |
| `process_storm` | Rapid process spawn/terminate | ~3 min |
| `network_burst` | HTTP request bursts | ~2 min |
| `rpc_generation` | WMI/RPC query loop | ~2 min |
| `service_cycle` | Service create/start/stop/delete | ~2 min |
| `user_account_modify` | User account create/modify/delete | ~1 min |
| `zip_extraction` | ZIP extraction workload | ~3 min |
| `combined_high_density` | All generators in parallel | ~5 min |
| `browser_streaming` | Browser streaming session | ~3 min |
| `driver_load` | Driver load via Defender restart | ~1 min |

---

## Parameter Reference

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-HeavyMode` | switch | off | Full workloads (default is Light mode) |
| `-EnableProfiling` | switch | off | Capture WPR/ETL traces per scenario |
| `-OnlyScenarios` | string[] | all | Run only listed scenarios |
| `-SkipScenarios` | string[] | none | Skip listed scenarios |
| `-PauseBetweenSeconds` | int | 30/60 | Pause between scenarios (30 light, 60 heavy) |
| `-SkipReports` | switch | off | Run scenarios but skip report generation |
| `-NumCores` | int | auto | CPU core count for % calculations |
| `-ReportsDir` | string | `C:\PerfTest\reports` | Output directory for reports |
| `-SymbolsDir` | string | -- | Path to PDB files for ETL function names |
| `-GenerateConfluence` | switch | off | Also produce Confluence-compatible HTML |
| `-ReportTag` | string | -- | Tag appended to report filenames (e.g., version) |

---

## PDB Symbols for Function Name Resolution

### What are PDB files?

PDB (Program Database) files are **debug symbol files** generated during compilation. They contain the mapping between binary memory addresses and human-readable function names, source file paths, and line numbers. Without PDB files, the ETL profiling report can only show raw hex addresses (e.g., `0x7ff61a2b3c4d`) instead of meaningful names like `PxMessages::SetEventCommonData`.

### Where to get PDB files

The PDB files must come from the **exact same build** as the sensor installed on the test machine. A GUID is embedded in both the `.exe`/`.dll` and the `.pdb` -- if they don't match, symbols won't resolve.

**Option A -- From a local build:**

If you built the sensor locally, the PDB files are in the build output directories:

```
<sensor-repo>\output\x64\Release\
├── ActiveProbe\Win\x64\Release\ActiveConsole.pdb
├── NnxSvc\Win\x64\Release\Nnx.pdb
├── CrsSvc\x64\Release\CrsSvc.pdb
├── BlockySvc\x64\Release\AmSvc.pdb
└── ...
```

Pass the root output directory as `-SymbolsDir` -- the script scans recursively for `.pdb` files.

**Option B -- From Jenkins artifacts:**

1. Go to the Jenkins build that produced the sensor version installed on the test machine:
   [https://jenkins-irelease.eng.cybereason.net/view/Release-Candidates/view/integration/job/msi-sensor-x64-release-build-integration/](https://jenkins-irelease.eng.cybereason.net/view/Release-Candidates/view/integration/job/msi-sensor-x64-release-build-integration/)
2. Find the build number matching your sensor version
3. Go to **Build Artifacts** and download `output-x64.zip`
4. Extract the archive to a local directory (e.g., `C:\Symbols\v26.1.30.1\`)
5. Pass that directory as `-SymbolsDir`:
   ```powershell
   .\Run-PerfTest.ps1 -EnableProfiling -SymbolsDir "C:\Symbols\v26.1.30.1"
   ```

### Troubleshooting symbols

If the ETL report still shows hex addresses after providing `-SymbolsDir`:
- Verify the sensor version matches the PDB version exactly (same build number)
- Check the build output contains `.pdb` files (not just `.exe`/`.dll`)
- The script prints how many PDB directories it found -- if it says 0, the path is wrong

---

## Output Structure

After a run, the target machine will have:

```
C:\PerfTest\
├── results\               <- Scenario JSON result files
│   ├── idle_baseline_20260222_103045.json
│   ├── file_stress_loop_20260222_104512.json
│   └── ...
├── traces\                <- ETL traces (only if -EnableProfiling)
│   ├── file_stress_loop_VM01_20260222_104512.etl
│   └── ...
└── ...

C:\PerfTest\reports\
├── sensor-perf-report-2026-02-22.html
├── sensor-perf-report-2026-02-22.confluence.html
├── etl-cpu-hotspots-report-2026-02-22.html
└── etl-cpu-hotspots-report-2026-02-22.confluence.html
```

---

## Tips

- **First run?** Start with a few scenarios to verify everything works:

```powershell
.\Run-PerfTest.ps1 -OnlyScenarios @("idle_baseline","file_stress_loop")
```

- **CPU overload?** On 2-core VMs the default Light mode should be fine. If you still see CPU saturation, run fewer scenarios at a time.

- **Re-generate reports** without re-running scenarios: use `generate-perf-report.ps1` directly:

```powershell
.\tools\generate-perf-report.ps1 -ScenarioResultsDir "C:\PerfTest\results" -NumCores 2 `
    -OutputPath "C:\PerfTest\reports\my-report.html" -SkipInfluxDB -SkipEtl
```

- **Compare versions**: Run on the same VM with different sensor versions, save reports with `-ReportTag`:

```powershell
.\Run-PerfTest.ps1 -ReportTag "v26.1.30.1"
# ... install new sensor version ...
.\Run-PerfTest.ps1 -ReportTag "v26.1.31.0"
```
