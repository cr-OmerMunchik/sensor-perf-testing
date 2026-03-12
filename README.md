# Sensor Performance Testing

Performance testing infrastructure for the ActiveProbe (Cybereason) Windows Sensor.

Two modes of operation are supported:

- **Self-Service** -- Run tests and generate reports on a single machine. No infrastructure needed.
- **Lab Environment** -- Multi-VM setup with Telegraf, InfluxDB, and Grafana for continuous monitoring and cross-VM comparison.

---

## Self-Service (Single Machine)

The fastest way to measure sensor performance. Run on any Windows VM or workstation with the sensor installed.

```powershell
# Clone the repo and run
git clone https://github.com/cr-OmerMunchik/sensor-perf-testing.git
cd sensor-perf-testing

# Default run (Light mode, ~45 min)
.\Run-PerfTest.ps1

# Heavy mode (full workloads, 4+ cores, ~3 hours)
.\Run-PerfTest.ps1 -HeavyMode

# With ETL CPU profiling + PDB symbols
.\Run-PerfTest.ps1 -EnableProfiling -SymbolsDir "C:\Symbols\v26.1.30.1"
```

This runs the test scenarios with inline metrics collection (Windows Performance Counters, 5-second interval), then generates HTML reports in `C:\PerfTest\reports\`:

- **Performance report** -- per-process CPU, memory, system memory, disk I/O, process uptime, DB size, KPI assessment with executive summary and conclusions
- **ETL profiling report** -- function-level CPU hotspots within sensor modules (requires `-EnableProfiling`)

> **Full guide**: [docs/self-service-guide.md](docs/self-service-guide.md)

---

## Lab Environment (Multi-VM with Monitoring)

For thorough, long-running analysis with real-time dashboards and cross-VM comparison (sensor vs. no-sensor).

### Architecture

```
+--------------------------------------------------------------+
|                    VMware Environment                         |
|                                                               |
|  +-------------+  +-------------+  +-------------+           |
|  | MON VM      |  | VM1         |  | VM2         |   ...     |
|  | InfluxDB    |  | No Sensor   |  | With Sensor |           |
|  | Grafana     |  | (baseline)  |  | (idle/load) |           |
|  | Small       |  | Large       |  | Large       |           |
|  | 2CPU / 4GB  |  | 8CPU / 16GB |  | 8CPU / 16GB |           |
|  +------^------+  +------+------+  +------+------+           |
|         |                |                |                   |
|         +--- Telegraf ---+--- Telegraf ---+                   |
|              (every 10s, metrics -> InfluxDB)                 |
+--------------------------------------------------------------+
```

### VM Roles

| VM | VMware Size | Specs | Purpose |
|----|-------------|-------|---------|
| MON | Small | 2 CPU / 4 GB | InfluxDB + Grafana (monitoring server) |
| test_perf_1 | Large | 8 CPU / 16 GB | No sensor -- bare OS baseline |
| test_perf_2 | Large | 8 CPU / 16 GB | Sensor installed, idle |
| test_perf_3 | Large | 8 CPU / 16 GB | Sensor installed + running scenarios |
| test_perf_4 | Large | 8 CPU / 16 GB | No sensor + running scenarios (workload cost) |

**Template OS**: Windows 11 Pro, Build 26200

### Setup Steps

1. Create VMs from VMware template
2. Enable SSH on each VM
3. Set up password-less SSH via `Setup-SSHKeys.ps1`
4. Set up MON VM with `Setup-MonVM.ps1` (installs InfluxDB + Grafana)
5. Deploy Telegraf to test VMs via `Deploy-TelegrafToAllVMs.ps1`
6. Import Grafana dashboards -- see [dashboards/README-import.md](dashboards/README-import.md)
7. Run tests from `test-scenarios/`

> **Full guide**: [docs/vm-setup-guide.md](docs/vm-setup-guide.md) | [Grafana guide](docs/grafana-guide.md) | [Running tests](docs/running-tests.md)

---

## Test Scenarios

### Event Generation Scenarios

| Scenario | Script | Key Events | Density |
|----------|--------|------------|---------|
| Browser Streaming | `Test-BrowserStreaming.ps1` | PROCESS, NETWORK, DNS, FILE, MODULE | Very High |
| File Stress Loop | `Test-FileStressLoop.ps1` | FILE_CREATED/RENAMED/DELETED | High |
| Registry Storm | `Test-RegistryStorm.ps1` | REGISTRY_VALUE_SET/DELETED | High |
| Network Burst | `Test-NetworkBurst.ps1` | NETWORK_*, DNS_QUERY | High |
| Service Cycle | `Test-ServiceCycle.ps1` | SERVICE_STARTED/STOPPED | Low |
| User Account Modify | `Test-UserAccountModify.ps1` | USER_MODIFIED | Low |
| RPC Generation | `Test-RpcGeneration.ps1` | RPC_CALL | Medium |
| Driver Load | `Test-DriverLoad.ps1` | DRIVER_LOADED | Low |
| Combined High-Density | `Test-CombinedHighDensity.ps1` | All 10+ types | Very High |

### Performance Workload Scenarios

| Scenario | Script | Description |
|----------|--------|-------------|
| Idle Baseline | `Test-IdleBaseline.ps1` | System at rest, measures baseline consumption |
| ZIP Extraction | `Test-ZipExtraction.ps1` | Extract 10K files, measures disk/CPU impact |
| File Storm | `Test-FileStorm.ps1` | Mass create/modify/delete with recovery pauses |
| Process Storm | `Test-ProcessStorm.ps1` | Rapid process spawn/terminate bursts |

## KPI Thresholds

| Metric | Idle Baseline | Under Load | Release Gate |
|--------|---------------|------------|--------------|
| CPU Usage | < 2% avg | < 15% sustained | Fail if exceeded > 5 min |
| Memory (RSS) | < 350 MB | < 500 MB peak | No growth trend over 72h |
| Disk IOPS | Minimal | No sustained | No disk thrashing |
| Network Usage | Predictable | No retry storms | No spike > SLA |
| Detection Latency | < 300 ms | < 500 ms | P95 within SLA |
| Boot Impact | < 5 sec | N/A | Fail if > 10 sec |

## Project Structure

```
sensor-perf-testing/
├── README.md                           # This file
├── Run-PerfTest.ps1                    # Single entry-point (self-service)
├── .gitignore
├── Setup-SSHKeys.ps1                   # SSH key deployment utility
├── Get-VMInfo.ps1                      # VM system info collector
├── docs/
│   ├── self-service-guide.md           # Self-service testing guide
│   ├── vm-setup-guide.md               # Multi-VM lab setup
│   ├── running-tests.md                # Test execution guide
│   ├── profiling-guide.md              # WPR/ETL profiling guide
│   └── grafana-guide.md                # Grafana usage guide
├── tools/
│   ├── generate-perf-report.ps1        # Report generator
│   ├── etl-analyzer/                   # ETL trace analyzer (.NET)
│   └── ...
├── test-scenarios/
│   ├── ScenarioHelpers.ps1             # Shared module (standard interface)
│   ├── Run-AllScenarios.ps1            # Orchestrator
│   ├── Test-IdleBaseline.ps1
│   ├── Test-FileStressLoop.ps1
│   ├── Test-RegistryStorm.ps1
│   └── ...                             # 13 scenario scripts total
├── setup-mon/                          # MON VM setup (lab environment)
├── setup-telegraf/                     # Telegraf setup (lab environment)
└── dashboards/                         # Grafana dashboards (lab environment)
```

## LoginVSI Integration (Future)

The test framework is designed for future LoginVSI integration:

1. **Self-contained scenarios** -- Each `.ps1` script can be called directly as a LoginVSI workload
2. **Standard interface** -- All scenarios use `ScenarioHelpers.ps1` for consistent start/stop/tagging
3. **JSON results** -- Every run outputs to `C:\PerfTest\results\` for machine parsing
4. **Scenario registry** -- `Run-AllScenarios.ps1` maps names to scripts, exportable to LoginVSI workload definitions

## Useful Commands

```powershell
# View all JSON results from a test run
Get-ChildItem C:\PerfTest\results\*.json |
    ForEach-Object { Get-Content $_ | ConvertFrom-Json } |
    Format-Table scenario, duration_seconds, host

# Check Telegraf status on a test VM (lab environment)
Get-Service telegraf

# Switch scenario tag manually (lab environment)
.\Switch-Scenario.ps1 -Scenario "your_scenario"
```

## Troubleshooting

### Scripts blocked by execution policy
- Run with: `powershell -ExecutionPolicy Bypass -File script.ps1`

### SSH connection refused
- Ensure sshd is running: `Get-Service sshd`
- Check firewall: `Get-NetFirewallRule -Name *ssh*`

### Telegraf service won't start (lab environment)
- Check the config: `& C:\InfluxData\telegraf\telegraf.exe --config C:\InfluxData\telegraf\telegraf.conf --test`
- Verify InfluxDB is reachable: `Test-NetConnection <MON_IP> -Port 8086`

### Grafana shows "No data" (lab environment)
- Verify the data source is configured correctly (Flux query language, correct token)
- Check that Telegraf is running on at least one test VM
- Try a narrower time range (Last 15 minutes)
