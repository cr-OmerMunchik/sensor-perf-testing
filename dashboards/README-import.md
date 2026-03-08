# Grafana Dashboard Import Instructions

## Step 1: Import the Pre-Built Windows Dashboard

1. Open Grafana: `http://MON_VM_IP:3000`
2. Go to **Dashboards** > **New** > **Import**
3. In the "Import via grafana.com" field, enter: **22226**
4. Click **Load**
5. Select your **InfluxDB-Perf** data source
6. Click **Import**

This gives you a general Windows metrics dashboard (CPU, memory, disk, network).

## Step 2: Import the Sensor Performance Dashboard

1. Go to **Dashboards** > **New** > **Import**
2. Click **Upload JSON file**
3. Select `sensor-performance-dashboard.json` from this directory
4. Select your **InfluxDB-Perf** data source for the `DS_INFLUXDB` input
5. Click **Import**

This dashboard includes:
- Sensor Process CPU Usage (per process)
- Sensor Process Memory Working Set (per process)
- Sensor Process Private Bytes (per process) -- for soak test leak detection
- Sensor Process Handle Count (per process) -- for handle leak detection
- Sensor Process Thread Count (per process)
- Sensor Process Disk I/O (per process)
- System CPU Usage with KPI thresholds (green <2%, yellow <15%, red >15%)
- System Available Memory
- System Disk IOPS
- System Network Throughput
- Kernel Pool Memory (paged + non-paged) -- for driver memory leaks
- Page Faults/sec
- Sensor Service Health Status (running/stopped indicator)

## Re-import / Update Dashboard

To push the latest dashboard (e.g. after fixes) to Grafana without using the UI:

```powershell
# Create a Grafana API key first: Configuration > API Keys > Add (Admin role)
$env:GRAFANA_API_KEY = "your-api-key"
.\tools\Import-GrafanaDashboard.ps1 -BackupFirst

# Or with basic auth (backs up existing dashboard before overwriting):
.\tools\Import-GrafanaDashboard.ps1 -BackupFirst -BasicAuth "admin:YOUR_PASSWORD"
```

Use `-BackupFirst` to save the current Grafana dashboard to `dashboards/sensor-performance-dashboard-backup-YYYYMMDD-HHMMSS.json` before overwriting.

## Using the Dashboard

At the top of the dashboard, you will see dropdown variables:
- **Host**: Select which VM(s) to display
- **Scenario**: Filter by test scenario (idle_baseline, zip_extraction, etc.)
- **Sensor Installed**: Filter by whether sensor is present (yes/no)

To compare BASELINE vs SENSOR:
- Select both hosts in the Host dropdown
- Or open two browser tabs side by side with different host selections
