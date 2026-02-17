# Sensor Performance Testing

Performance testing infrastructure for the ActiveProbe (Cybereason) Windows Sensor using the **TIG Stack** (Telegraf + InfluxDB + Grafana).

## Architecture

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

## VM Roles

| VM | VMware Size | Specs | Purpose |
|----|-------------|-------|---------|
| MON | Small | 2 CPU / 4 GB | InfluxDB + Grafana (monitoring server) |
| test_perf_1 | Large | 8 CPU / 16 GB | No sensor -- bare OS baseline |
| test_perf_2 | Large | 8 CPU / 16 GB | Sensor installed, idle |
| test_perf_3 | Large | 8 CPU / 16 GB | Sensor installed + running scenarios |
| test_perf_4 | Large | 8 CPU / 16 GB | No sensor + running scenarios (workload cost) |

**Template OS**: Windows 11 Pro, Build 26200

## Prerequisites

### 1. Create VMs from VMware template

Create VMs using the DevOps-provided VMware template. You need at minimum:
- 1 Small VM (MON)
- 2+ Large VMs (test machines)

### 2. Enable SSH on each VM

Run on each VM (via VMware console or RDP):

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

### 3. Set up password-less SSH

From your workstation, run the included helper script:

```powershell
powershell -ExecutionPolicy Bypass -File Setup-SSHKeys.ps1
```

Edit the `$vms` array in the script to match your VM IPs. You will be prompted for the password once per VM.

### 4. Set up the MON VM

Copy `setup-mon/` to the MON VM and run:

```powershell
.\Setup-MonVM.ps1
```

Then complete the manual steps (InfluxDB wizard, API token, Grafana data source).

### 5. Deploy Telegraf to test VMs

Copy `setup-telegraf/` to each test VM and run:

```powershell
# No sensor VM:
.\Install-Telegraf.ps1 -MonVmIp "172.46.16.24" -InfluxToken "YOUR_TOKEN" -SensorInstalled "no"

# Sensor VM:
.\Install-Telegraf.ps1 -MonVmIp "172.46.16.24" -InfluxToken "YOUR_TOKEN" -SensorInstalled "yes"
```

### 6. Import Grafana dashboards

See [dashboards/README-import.md](dashboards/README-import.md).

### 7. Run tests

Copy `test-scenarios/` to the test VMs and run:

```powershell
# Run all scenarios in sequence
.\Run-AllScenarios.ps1

# Run specific scenarios
.\Run-AllScenarios.ps1 -OnlyScenarios @("file_stress_loop", "registry_storm")
```

> **Detailed guides**: See the [docs/](docs/) folder for step-by-step walkthroughs on [VM Setup](docs/vm-setup-guide.md), [Using Grafana](docs/grafana-guide.md), and [Running Tests](docs/running-tests.md).

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
├── .gitignore
├── Setup-SSHKeys.ps1                   # SSH key deployment utility
├── Get-VMInfo.ps1                      # VM system info collector
├── setup-mon/
│   ├── Setup-MonVM.ps1                 # Master MON VM setup (runs all below)
│   ├── Install-InfluxDB.ps1            # InfluxDB v2.8.0 installation
│   ├── Install-Grafana.ps1             # Grafana v11.5.2 installation
│   └── Configure-Firewall.ps1          # Opens ports 8086, 3000
├── setup-telegraf/
│   ├── Install-Telegraf.ps1            # Telegraf v1.37.2 installation + config
│   └── telegraf.conf                   # Telegraf config template
├── dashboards/
│   ├── sensor-performance-dashboard.json  # Custom Grafana dashboard
│   └── README-import.md                # Import instructions
├── test-scenarios/
│   ├── ScenarioHelpers.ps1             # Shared module (standard interface)
│   ├── Switch-Scenario.ps1             # Change Telegraf scenario tag
│   ├── Run-AllScenarios.ps1            # Orchestrator (LoginVSI replacement)
│   ├── Test-IdleBaseline.ps1           # Idle baseline
│   ├── Test-FileStressLoop.ps1         # File stress loop
│   ├── Test-RegistryStorm.ps1          # Registry storm
│   ├── Test-NetworkBurst.ps1           # Network burst
│   ├── Test-ProcessStorm.ps1           # Process spawn/terminate
│   ├── Test-RpcGeneration.ps1          # RPC via WMI
│   ├── Test-ServiceCycle.ps1           # Service start/stop
│   ├── Test-UserAccountModify.ps1      # User account modify
│   ├── Test-BrowserStreaming.ps1       # Browser streaming
│   ├── Test-DriverLoad.ps1             # Driver load
│   ├── Test-ZipExtraction.ps1          # ZIP extraction
│   ├── Test-FileStorm.ps1              # File storm
│   └── Test-CombinedHighDensity.ps1    # All generators combined
└── docs/
    ├── vm-setup-guide.md               # Full VM setup walkthrough
    ├── grafana-guide.md                # Grafana usage guide
    ├── running-tests.md                # Test execution guide
    └── confluence/                     # Paste-ready Confluence pages
        ├── vm-setup-guide.html
        ├── grafana-guide.html
        └── running-tests.html
```

## LoginVSI Integration (Future)

The test framework is designed for future LoginVSI integration:

1. **Self-contained scenarios** -- Each `.ps1` script can be called directly as a LoginVSI workload
2. **Standard interface** -- All scenarios use `ScenarioHelpers.ps1` for consistent start/stop/tagging
3. **JSON results** -- Every run outputs to `C:\PerfTest\results\` for machine parsing
4. **Scenario registry** -- `Run-AllScenarios.ps1` maps names to scripts, exportable to LoginVSI workload definitions

## Useful Commands

```powershell
# Check Telegraf status on a test VM
Get-Service telegraf

# Restart Telegraf after config change
Restart-Service telegraf

# Test Telegraf config (prints metrics to console)
& C:\InfluxData\telegraf\telegraf.exe --config C:\InfluxData\telegraf\telegraf.conf --test

# Check connectivity to MON VM
Test-NetConnection 172.46.16.24 -Port 8086

# Switch scenario tag manually
.\Switch-Scenario.ps1 -Scenario "your_scenario"

# View all JSON results from a test run
Get-ChildItem C:\PerfTest\results\*.json |
    ForEach-Object { Get-Content $_ | ConvertFrom-Json } |
    Format-Table scenario, duration_seconds, host
```

## Troubleshooting

### Telegraf service won't start
- Check the config: `& C:\InfluxData\telegraf\telegraf.exe --config C:\InfluxData\telegraf\telegraf.conf --test`
- Verify InfluxDB is reachable: `Test-NetConnection 172.46.16.24 -Port 8086`
- Check Windows Event Viewer > Application > Source: telegraf

### InfluxDB not accessible
- Verify the scheduled task is running: `Get-ScheduledTask -TaskName "InfluxDB"`
- Start manually: `Start-ScheduledTask -TaskName "InfluxDB"`
- Check process: `Get-Process influxd`

### Grafana shows "No data"
- Verify the data source is configured correctly (Flux query language, correct token)
- Check that Telegraf is running on at least one test VM
- Try a narrower time range (Last 15 minutes)
- Verify the bucket name is `telegraf`

### SSH connection refused
- Ensure sshd is running: `Get-Service sshd`
- Check firewall: `Get-NetFirewallRule -Name *ssh*`

### Scripts blocked by execution policy
- Run with: `powershell -ExecutionPolicy Bypass -File script.ps1`
