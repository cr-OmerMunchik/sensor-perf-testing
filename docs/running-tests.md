# Running Performance Tests -- Sensor Performance Testing

How to execute test scenarios, monitor them in real-time, and review results.

## Overview

### What are the test scenarios?

The test scenarios are PowerShell scripts that generate specific types of system activity -- file operations, registry writes, network traffic, process spawning, etc. These are the kinds of events that the ActiveProbe sensor monitors and reacts to. By running these workloads on VMs with and without the sensor, you can measure exactly how much overhead the sensor adds.

### How scenarios work with the monitoring stack

Each scenario script:
1. **Tags the metrics** -- Calls `Switch-Scenario.ps1` which updates the `scenario` tag in Telegraf's configuration and restarts the service. From that point on, all metrics collected by Telegraf on that VM are tagged with the scenario name (e.g., `file_stress_loop`).
2. **Runs the workload** -- Performs the actual system activity (creating files, writing registry keys, spawning processes, etc.)
3. **Saves results** -- Writes timing and metadata to a JSON file at `C:\PerfTest\results\` for offline analysis.

While the scenario runs, Telegraf continues collecting metrics every 10 seconds and sending them to InfluxDB. You can watch the impact in real-time in Grafana, or review it later by filtering on the scenario tag.

### Where to get the scripts

All test scenario scripts are in the `test-scenarios/` folder of the GitHub repository:

**https://github.com/cr-OmerMunchik/sensor-perf-testing**

Clone the repo and copy the `test-scenarios/` folder to the VMs that will run workloads:

```powershell
git clone https://github.com/cr-OmerMunchik/sensor-perf-testing.git
cd sensor-perf-testing
scp -r test-scenarios admin@<VM_IP>:C:\test-scenarios
```

## VM Roles Recap

| VM | Sensor | Scenarios | Purpose |
|----|--------|-----------|---------|
| test_perf_1 | No | No | Bare OS idle baseline |
| test_perf_2 | Yes | No | Sensor idle overhead |
| test_perf_3 | Yes | Yes | Sensor under load |
| test_perf_4 | No | Yes | Pure workload cost (no sensor) |

## Pre-Flight Checklist

Before running tests, verify:

```powershell
# On each test VM, check Telegraf is running
Get-Service telegraf

# On MON VM, check InfluxDB and Grafana
Get-Process influxd
Get-Service Grafana

# From your workstation, check connectivity
Test-NetConnection 172.46.16.24 -Port 8086
Test-NetConnection 172.46.16.24 -Port 3000
```

Open Grafana and confirm you see data from all VMs in the Host dropdown.

## Deploying Scenarios to VMs

From your workstation, in the cloned `sensor-perf-testing` repo directory, copy `test-scenarios/` to the VMs that will run workloads:

```powershell
cd sensor-perf-testing
scp -r test-scenarios admin@172.46.16.176:C:\test-scenarios   # VM3 (sensor + scenarios)
scp -r test-scenarios admin@172.46.21.24:C:\test-scenarios     # VM4 (no sensor + scenarios)
```

## Running All Scenarios

SSH into the test VM and run:

```powershell
cd C:\test-scenarios
powershell -ExecutionPolicy Bypass -File Run-AllScenarios.ps1
```

This runs all 13 scenarios in sequence:

| # | Scenario | Description | Est. Runtime |
|---|----------|-------------|-------------|
| 1 | idle_baseline | System at rest | 15 min |
| 2 | file_stress_loop | File create/rename/delete loop (5000 x 100) | ~14 min |
| 3 | registry_storm | Registry set/delete storm (2000 x 100) | ~12 min |
| 4 | network_burst | HTTP request burst (300 x 50) | ~15 min |
| 5 | process_storm | Rapid process spawn/terminate (100 x 30) | ~13 min |
| 6 | rpc_generation | WMI/RPC query loop (500 x 25) | ~15 min |
| 7 | service_cycle | Service create/start/stop/delete (200 cycles) | ~7 min |
| 8 | user_account_modify | User account create/modify/delete (200 cycles) | ~5 min |
| 9 | browser_streaming | Browser streaming session | 15 min |
| 10 | driver_load | Driver load via Defender restart (10 cycles) | ~3 min |
| 11 | zip_extraction | ZIP archive create/extract (10000 x 10) | ~12 min |
| 12 | file_storm | Mass file operations in bursts (10000 x 30) | ~12 min |
| 13 | combined_high_density | All generators in parallel | 15 min |

Between each scenario there is a **60-second pause** to create clean separation in Grafana graphs.

**Total estimated runtime: ~3-4 hours** (scenarios + pauses).

### Options

```powershell
# Shorter pauses between scenarios
.\Run-AllScenarios.ps1 -PauseBetweenSeconds 30

# Run only specific scenarios
.\Run-AllScenarios.ps1 -OnlyScenarios @("file_stress_loop", "registry_storm", "network_burst")

# Skip scenarios that need special setup
.\Run-AllScenarios.ps1 -SkipScenarios @("browser_streaming", "driver_load")

# Run with WPR profiling (captures .etl traces to C:\PerfTest\traces\)
.\Run-AllScenarios.ps1 -EnableProfiling -OnlyScenarios @("user_account_modify", "combined_high_density")

# Profile with custom WPR profiles (e.g., add heap tracking)
.\Run-AllScenarios.ps1 -EnableProfiling -ProfilingProfiles @("GeneralProfile", "DiskIO", "Heap")
```

See [Profiling Guide](profiling-guide.md) for trace capture and analysis.

## Running Tests with Profiling

To capture WPR (Windows Performance Recorder) traces during scenarios:

1. **On the test VM:** Run with `-EnableProfiling`:
   ```powershell
   .\Run-AllScenarios.ps1 -EnableProfiling -OnlyScenarios @("user_account_modify", "combined_high_density")
   ```
   Traces are saved to `C:\PerfTest\traces\` on the VM.

2. **From your workstation:** Collect traces to your workstation:
   ```powershell
   cd sensor-perf-testing
   .\test-scenarios\Collect-Traces.ps1
   ```
   Traces are organized by date: `C:\PerfTest\collected-traces\<date>\*.etl`

3. **Analyze:** Use WPA (interactive) or the ETL Analyzer (automated). See [Profiling Guide](profiling-guide.md) for details.

4. **Generate reports:** Use `generate-perf-report.ps1` or `generate-executive-summary.ps1` — see [tools/README.md](../tools/README.md).

## Telegraf Tags (num_cores, sensor_version)

Telegraf adds tags to each metric for filtering and normalization:

| Tag | Description | Example |
|-----|-------------|---------|
| **num_cores** | CPU cores for normalization (sensor CPU ÷ num_cores = % of total system) | `8` |
| **sensor_version** | Sensor version (e.g., `26.1.42`), auto-detected or set during Install-Telegraf | `26.1.42` or empty for no-sensor VMs |

These tags are set when you install Telegraf (see [VM Setup Guide](vm-setup-guide.md)). Grafana uses them for CPU normalization and to filter by sensor version. Older data may have `sensor_version=""`; `$__all` in the dashboard includes that data.

## Running Individual Scenarios

You can run any scenario independently:

```powershell
# File operations (~12-14 min each)
.\Test-FileStressLoop.ps1 -LoopCount 5000 -Iterations 100
.\Test-FileStorm.ps1 -FileCount 10000 -Bursts 30
.\Test-ZipExtraction.ps1 -FileCount 10000 -Iterations 10

# System events (~12-15 min each)
.\Test-RegistryStorm.ps1 -LoopCount 2000 -Iterations 100
.\Test-ProcessStorm.ps1 -ProcessCount 100 -Bursts 30
.\Test-NetworkBurst.ps1 -RequestCount 300 -Iterations 50
.\Test-RpcGeneration.ps1 -QueryCount 500 -Iterations 25

# Admin-required scenarios (~3-7 min each)
.\Test-ServiceCycle.ps1 -Cycles 200
.\Test-UserAccountModify.ps1 -Cycles 200
.\Test-DriverLoad.ps1 -Cycles 10

# Long-running scenarios (15 min each)
.\Test-IdleBaseline.ps1 -DurationMinutes 15
.\Test-BrowserStreaming.ps1 -DurationSeconds 900
.\Test-CombinedHighDensity.ps1 -DurationSeconds 900
```

Each scenario automatically:
1. Switches the Telegraf `scenario` tag (for Grafana filtering)
2. Runs the workload
3. Saves results as JSON to `C:\PerfTest\results\`

## Running Tests on Multiple VMs Simultaneously

For the best comparison data, run the same scenarios on VM3 (with sensor) and VM4 (without sensor) at the same time:

**Terminal 1:**
```powershell
ssh admin@172.46.16.176   # VM3 (sensor)
cd C:\test-scenarios
powershell -ExecutionPolicy Bypass -File Run-AllScenarios.ps1
```

**Terminal 2:**
```powershell
ssh admin@172.46.21.24    # VM4 (no sensor)
cd C:\test-scenarios
powershell -ExecutionPolicy Bypass -File Run-AllScenarios.ps1
```

Both VMs will run the same workloads at roughly the same time, giving you a direct comparison of the sensor's impact.

## Monitoring Tests in Real-Time

While tests are running:

1. Open Grafana (`http://172.46.16.24:3000`)
2. Go to the **ActiveProbe Sensor Performance** dashboard
3. Set time range to **Last 30 minutes** with **10s auto-refresh**
4. Select the test VM(s) in the **Host** dropdown
5. Watch the metrics update live

You'll see clear transitions between scenarios thanks to the pause gaps.

## Reviewing Results After a Test Run

### In Grafana

1. Set the time range to cover the entire test run
2. Use the **Scenario** dropdown to filter by scenario
3. Compare hosts by selecting multiple in the **Host** dropdown

### JSON Results

Each scenario saves a JSON file on the test VM:

```powershell
# List all results
Get-ChildItem C:\PerfTest\results\*.json

# View results as a table
Get-ChildItem C:\PerfTest\results\*.json |
    ForEach-Object { Get-Content $_ | ConvertFrom-Json } |
    Format-Table scenario, duration_seconds, host

# Copy results to your workstation
scp admin@172.46.16.176:C:\PerfTest\results\*.json C:\results\vm3\
scp admin@172.46.21.24:C:\PerfTest\results\*.json C:\results\vm4\
```

## Adding a New Scenario

1. Create a new `Test-YourScenario.ps1` in `test-scenarios/`:

```powershell
#Requires -RunAsAdministrator  # only if needed
. "$PSScriptRoot\ScenarioHelpers.ps1"

param(
    [int]$YourParam = 100
)

Start-Scenario -Name "your_scenario" -Description "What this scenario does"

# ... your workload code ...

Add-ScenarioMetric -Key "items_processed" -Value $count
Complete-Scenario
```

2. Add it to the `$AllScenarios` registry in `Run-AllScenarios.ps1`:

```powershell
"your_scenario" = @{
    Script = "Test-YourScenario.ps1"
    Params = @{ YourParam = 100 }
    Description = "Description of your scenario"
    RequiresAdmin = $false
}
```

3. Add the scenario name to the list in `Switch-Scenario.ps1` comments.

## Troubleshooting

### Scenario fails with "Access Denied"
Some scenarios (service_cycle, user_account_modify, driver_load) require admin privileges. Make sure you're running PowerShell as Administrator.

### Telegraf scenario tag not updating
Check that `Switch-Scenario.ps1` can find the config:
```powershell
Test-Path C:\InfluxData\telegraf\telegraf.conf
```

### Results directory not created
The scripts create `C:\PerfTest\results\` automatically. If it fails, create it manually:
```powershell
New-Item -ItemType Directory -Path C:\PerfTest\results -Force
```

### Browser streaming scenario fails
This scenario opens Microsoft Edge. If Edge is not installed or the VM has no display, skip it:
```powershell
.\Run-AllScenarios.ps1 -SkipScenarios @("browser_streaming")
```
