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
| 1 | idle_baseline | System at rest | 10 min |
| 2 | file_stress_loop | File create/rename/delete loop | ~2 min |
| 3 | registry_storm | Registry set/delete storm | ~2 min |
| 4 | network_burst | HTTP request burst | ~2 min |
| 5 | process_storm | Rapid process spawn/terminate | ~2 min |
| 6 | rpc_generation | WMI/RPC query loop | ~2 min |
| 7 | service_cycle | Service create/start/stop/delete | ~1 min |
| 8 | user_account_modify | User account create/modify/delete | ~1 min |
| 9 | browser_streaming | Browser streaming session | 5 min |
| 10 | driver_load | Driver load via Defender restart | ~1 min |
| 11 | zip_extraction | ZIP archive create/extract | ~3 min |
| 12 | file_storm | Mass file operations in bursts | ~2 min |
| 13 | combined_high_density | All generators in parallel | 7 min |

Between each scenario there is a **60-second pause** to create clean separation in Grafana graphs.

**Total estimated runtime: ~50-60 minutes.**

### Options

```powershell
# Shorter pauses between scenarios
.\Run-AllScenarios.ps1 -PauseBetweenSeconds 30

# Run only specific scenarios
.\Run-AllScenarios.ps1 -OnlyScenarios @("file_stress_loop", "registry_storm", "network_burst")

# Skip scenarios that need special setup
.\Run-AllScenarios.ps1 -SkipScenarios @("browser_streaming", "driver_load")
```

## Running Individual Scenarios

You can run any scenario independently:

```powershell
# File operations
.\Test-FileStressLoop.ps1 -LoopCount 1000 -Iterations 3
.\Test-FileStorm.ps1 -FileCount 5000 -Bursts 3
.\Test-ZipExtraction.ps1 -FileCount 10000 -Iterations 3

# System events
.\Test-RegistryStorm.ps1 -LoopCount 500 -Iterations 3
.\Test-ProcessStorm.ps1 -ProcessCount 200 -Bursts 3
.\Test-NetworkBurst.ps1 -RequestCount 200 -Iterations 3
.\Test-RpcGeneration.ps1 -QueryCount 300 -Iterations 3

# Admin-required scenarios
.\Test-ServiceCycle.ps1 -Cycles 10
.\Test-UserAccountModify.ps1 -Cycles 10
.\Test-DriverLoad.ps1 -Cycles 3

# Long-running scenarios
.\Test-IdleBaseline.ps1 -DurationMinutes 60
.\Test-BrowserStreaming.ps1 -DurationSeconds 300
.\Test-CombinedHighDensity.ps1 -DurationSeconds 420
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
