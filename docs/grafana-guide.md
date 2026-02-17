# Grafana Usage Guide -- Sensor Performance Testing

How to use Grafana to monitor, compare, and analyze sensor performance metrics.

## Accessing Grafana

- **URL**: `http://<MON_VM_IP>:3000` (e.g., `http://172.46.16.24:3000`)
- **Login**: `admin` / (the password you set during setup)

## Dashboards

You have two dashboards:

### 1. Telegraf Windows Metrics (ID 22226)

General OS-level metrics for any Windows machine:
- CPU usage (total and per-core)
- Memory (available, committed, paged/nonpaged pool)
- Disk I/O (reads/writes per second, queue length, latency)
- Network (bytes/packets in/out, errors)
- System overview (processes, threads, context switches)

### 2. ActiveProbe Sensor Performance (Custom)

Purpose-built dashboard for sensor testing:

| Panel | What It Shows | What to Look For |
|-------|---------------|------------------|
| Sensor Process CPU | CPU % per sensor process | Should be < 2% idle, < 15% under load |
| Sensor Process Memory (Working Set) | Physical memory per process | Should be < 350 MB idle, < 500 MB peak |
| Sensor Process Private Bytes | Committed memory per process | Steady growth = memory leak |
| Sensor Process Handles | Handle count per process | Steady growth = handle leak |
| Sensor Process Threads | Thread count per process | Unexpected growth = thread leak |
| Sensor Process Disk I/O | Read/write bytes per second per process | Spikes during scenarios are OK |
| System CPU with KPI Lines | Total CPU with threshold markers | Green < 2%, Yellow < 15%, Red > 15% |
| System Memory | Available memory over time | Steady decrease = leak somewhere |
| System Disk IOPS | Total disk operations per second | Sustained high = disk thrashing |
| System Network | Bytes sent/received per second | Look for retry storms |
| Kernel Pool Memory | Paged + nonpaged pool bytes | Growth can indicate driver leaks |
| Page Faults/sec | Memory pressure indicator | High sustained = memory pressure |
| Sensor Service Health | Running/stopped status per service | Should all be "4" (running) |

## Using the Dashboard Controls

### Time Range Picker (top-right)

- **Real-time monitoring**: Select "Last 15 minutes" or "Last 1 hour" with auto-refresh ON
- **Reviewing a past test**: Click and set a custom time range covering the test period
- **Quick zoom**: Click and drag on any graph to zoom into a specific time window
- **Zoom out**: Click the back arrow next to the time picker

### Auto-Refresh (next to time picker)

- Set to **10s** or **30s** during live monitoring
- Turn **Off** when reviewing historical data (to avoid the dashboard jumping)

### Template Variables (top of dashboard)

These dropdowns filter what data is shown:

- **Host**: Select one or more VMs. Multi-select lets you compare side by side.
- **Scenario**: Filter by test scenario tag (e.g., `idle_baseline`, `file_stress_loop`)
- **Sensor Installed**: Filter by `yes` or `no`

## Common Tasks

### Compare sensor overhead (with vs. without)

1. In the **Host** dropdown, select both a sensor VM and a no-sensor VM
2. Both lines appear on the same graph with different colors
3. The gap between the lines is the sensor overhead

### Compare scenarios

1. Run different scenarios at different times
2. Set the time range to cover all scenarios
3. Use the **Scenario** dropdown to filter one at a time
4. Or view all scenarios together -- the gaps between them (from `Run-AllScenarios.ps1` pauses) make them easy to distinguish

### Detect memory or handle leaks

1. Open the **Sensor Process Private Bytes** or **Handle Count** panel
2. Set the time range to a long period (e.g., a soak test)
3. A steady upward trend (not just spikes) indicates a leak
4. Click the panel title > **View** to see it full-screen for better detail

### Check if KPIs pass

1. Open the **System CPU with KPI Lines** panel
2. The green/yellow/red threshold lines are drawn on the graph
3. If the CPU line stays below the green threshold during idle, and below yellow under load, the KPI passes
4. Cross-reference with the KPI table in the README

### Export a graph as an image

1. Hover over a panel and click the panel title
2. Select **Share** (or click the share icon)
3. Go to the **Snapshot** or **Direct link** tab
4. Or simply take a screenshot for reports

### Full-screen a panel

1. Hover over a panel
2. Click the panel title > **View** (or press `V`)
3. Press `Esc` to return

## Grafana Query Tips

If you want to explore data beyond the pre-built dashboards:

1. Go to **Explore** (compass icon in the left sidebar)
2. Select the **InfluxDB** data source
3. Write a Flux query. Examples:

**Get CPU usage for a specific host:**
```flux
from(bucket: "telegraf")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> filter(fn: (r) => r._field == "Percent_Processor_Time")
  |> filter(fn: (r) => r.host == "DESKTOP-H57VD4J")
```

**Get sensor process memory:**
```flux
from(bucket: "telegraf")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "sensor_process")
  |> filter(fn: (r) => r._field == "Working_Set")
  |> filter(fn: (r) => r.instance == "ActiveConsole")
```

**Compare two hosts:**
```flux
from(bucket: "telegraf")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> filter(fn: (r) => r._field == "Percent_Processor_Time")
  |> filter(fn: (r) => r.host == "DESKTOP-H57VD4J" or r.host == "DESKTOP-ABC123")
```

## Alerts (Optional)

You can set up Grafana alerts to notify when KPIs are breached:

1. Edit a panel
2. Go to the **Alert** tab
3. Create a rule, e.g., "Alert when CPU > 15% for 5 minutes"
4. Configure a notification channel (email, Slack, etc.)

This is optional and can be configured later.
