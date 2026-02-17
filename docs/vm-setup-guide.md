# VM Setup Guide -- Sensor Performance Testing

Complete step-by-step guide for setting up the performance testing environment from scratch.

## Overview

The environment consists of:
- **1 MON VM** (Small: 2 CPU / 4 GB) -- runs InfluxDB and Grafana
- **2-4 Test VMs** (Large: 8 CPU / 16 GB) -- run Telegraf + test scenarios

All VMs are Windows 11 Pro (Build 26200), created from a VMware template.

## Step 1: Create VMs

Create VMs from the DevOps-provided VMware template:

| VM Name | Size | Purpose |
|---------|------|---------|
| test_perf_mon | Small (2 CPU / 4 GB) | Monitoring server |
| test_perf_1 | Large (8 CPU / 16 GB) | No sensor (baseline) |
| test_perf_2 | Large (8 CPU / 16 GB) | Sensor installed, idle |
| test_perf_3 | Large (8 CPU / 16 GB) | Sensor + scenarios |
| test_perf_4 | Large (8 CPU / 16 GB) | No sensor + scenarios |

> **Why these roles?** Having VMs with and without the sensor, both idle and under load, lets you calculate the exact overhead the sensor adds in each condition.

## Step 2: Enable SSH on All VMs

Connect to each VM via VMware console or RDP and run:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
New-NetFirewallRule -Name "OpenSSH-Server" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue
```

## Step 3: Set Up Password-less SSH

On your workstation, edit `Setup-SSHKeys.ps1` and update the `$vms` array with your VM IPs:

```powershell
$vms = @(
    "172.46.16.24",   # test_perf_mon
    "172.46.16.37",   # test_perf_1
    "172.46.17.49",   # test_perf_2
    "172.46.16.176",  # test_perf_3
    "172.46.21.24"    # test_perf_4
)
```

Then run:

```powershell
powershell -ExecutionPolicy Bypass -File Setup-SSHKeys.ps1
```

This generates an SSH key (if you don't have one), copies it to all VMs, and tests connectivity. You'll need to enter the password once per VM.

> **Note**: The script uses `C:\ProgramData\ssh\administrators_authorized_keys` because Windows OpenSSH ignores per-user authorized_keys for admin accounts.

## Step 4: Set Up the MON VM

### 4.1 Copy setup files

From your workstation:

```powershell
scp -r setup-mon admin@172.46.16.24:C:\setup-mon
scp -r dashboards admin@172.46.16.24:C:\setup-mon\dashboards
```

### 4.2 Run the setup script

SSH into the MON VM and run:

```powershell
ssh admin@172.46.16.24
cd C:\setup-mon
powershell -ExecutionPolicy Bypass -File Setup-MonVM.ps1
```

This installs InfluxDB (as a scheduled task) and Grafana (as a Windows service), and opens firewall ports 8086 and 3000.

### 4.3 Configure InfluxDB

Open `http://<MON_VM_IP>:8086` in a browser (from the MON VM or any machine with access).

1. Complete the setup wizard:
   - **Username**: `admin`
   - **Password**: choose a strong password
   - **Organization**: `activeprobe-perf`
   - **Bucket**: `telegraf`
2. On the completion screen, **copy the API token** and save it. You will not be able to see it again.
3. Click **Configure Later**

### 4.4 Create an additional API token (if needed)

If you missed the initial token:

1. Go to **Load Data** (left sidebar) > **API Tokens**
2. Click **Generate API Token** > **All Access API Token**
3. Name it `telegraf-writer`
4. Copy and save the token

### 4.5 Configure Grafana

Open `http://<MON_VM_IP>:3000` in a browser.

1. Log in with `admin` / `admin` (you'll be asked to change the password)
2. Go to **Connections** > **Data Sources** > **Add data source**
3. Select **InfluxDB**
4. Configure:
   - **Query Language**: change dropdown to **Flux** (this is critical -- the default is InfluxQL)
   - **URL**: `http://localhost:8086`
   - Scroll down to **InfluxDB Details**:
     - **Organization**: `activeprobe-perf`
     - **Token**: paste the API token from step 4.3
     - **Default Bucket**: `telegraf`
5. Click **Save & Test** -- should say "datasource is working"

### 4.6 Import dashboards

**Dashboard 1 -- General Windows Metrics:**

1. Go to **Dashboards** > **New** > **Import** (or navigate to `http://<MON_VM_IP>:3000/dashboard/import`)
2. Enter ID **22226** and click **Load**
3. Select your InfluxDB data source from the dropdown
4. Click **Import**

**Dashboard 2 -- ActiveProbe Sensor Performance:**

1. Go to **Dashboards** > **New** > **Import**
2. Click **Upload dashboard JSON file**
3. Select `sensor-performance-dashboard.json` (should be at `C:\setup-mon\dashboards\` on the MON VM)
4. Select your InfluxDB data source
5. Click **Import**

## Step 5: Deploy Telegraf to Test VMs

### 5.1 Copy setup files

From your workstation, copy to each test VM:

```powershell
scp -r setup-telegraf admin@172.46.16.37:C:\setup-telegraf
scp -r setup-telegraf admin@172.46.17.49:C:\setup-telegraf
scp -r setup-telegraf admin@172.46.16.176:C:\setup-telegraf
scp -r setup-telegraf admin@172.46.21.24:C:\setup-telegraf
```

### 5.2 Run the install script on each VM

SSH into each VM and run with the appropriate parameters:

**test_perf_1** (no sensor, baseline):
```powershell
cd C:\setup-telegraf
powershell -ExecutionPolicy Bypass -File Install-Telegraf.ps1 -MonVmIp "172.46.16.24" -InfluxToken "YOUR_TOKEN" -SensorInstalled "no"
```

**test_perf_2** (sensor installed, idle):
```powershell
cd C:\setup-telegraf
powershell -ExecutionPolicy Bypass -File Install-Telegraf.ps1 -MonVmIp "172.46.16.24" -InfluxToken "YOUR_TOKEN" -SensorInstalled "yes"
```

**test_perf_3** (sensor + scenarios):
```powershell
cd C:\setup-telegraf
powershell -ExecutionPolicy Bypass -File Install-Telegraf.ps1 -MonVmIp "172.46.16.24" -InfluxToken "YOUR_TOKEN" -SensorInstalled "yes"
```

**test_perf_4** (no sensor + scenarios):
```powershell
cd C:\setup-telegraf
powershell -ExecutionPolicy Bypass -File Install-Telegraf.ps1 -MonVmIp "172.46.16.24" -InfluxToken "YOUR_TOKEN" -SensorInstalled "no"
```

Replace `YOUR_TOKEN` with the actual InfluxDB API token from step 4.3.

### 5.3 Verify data flow

After installing Telegraf on all VMs:

1. Open Grafana (`http://<MON_VM_IP>:3000`)
2. Go to the **Telegraf Windows Metrics** dashboard
3. Set the time range to **Last 15 minutes**
4. You should see metrics from all connected VMs in the **Host** dropdown

## Step 6: Install the ActiveProbe Sensor

Install the sensor on the designated VMs (test_perf_2 and test_perf_3). Follow your standard sensor installation procedure.

After installation, verify the sensor processes appear in Telegraf:

```powershell
# On the VM with the sensor
& C:\InfluxData\telegraf\telegraf.exe --config C:\InfluxData\telegraf\telegraf.conf --test 2>&1 | Select-String "sensor_process"
```

You should see lines with metrics for processes like `ActiveConsole`, `minionhost`, `CrsSvc`, etc.

## Step 7: Deploy Test Scenarios

Copy the test scenarios to VM3 and VM4:

```powershell
scp -r test-scenarios admin@172.46.16.176:C:\test-scenarios
scp -r test-scenarios admin@172.46.21.24:C:\test-scenarios
```

See [Running Tests](running-tests.md) for how to execute them.

## Verification Checklist

After completing all steps, verify:

- [ ] All VMs are reachable via SSH without password
- [ ] MON VM: InfluxDB is running (`Get-Process influxd` or `Get-ScheduledTask -TaskName "InfluxDB"`)
- [ ] MON VM: Grafana is running (`Get-Service Grafana`)
- [ ] MON VM: Grafana can query InfluxDB (data source shows "working")
- [ ] Test VMs: Telegraf is running (`Get-Service telegraf`)
- [ ] Grafana: All test VM hostnames appear in the Host dropdown
- [ ] Sensor VMs: Sensor processes appear in the Sensor Performance dashboard
