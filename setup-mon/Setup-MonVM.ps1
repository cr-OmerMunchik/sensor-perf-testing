#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Master setup script for the MON VM. Runs all installation steps in sequence.

.DESCRIPTION
    Installs InfluxDB, Grafana, and configures the firewall on the MON VM.
    After running this script, you still need to:
      1. Complete the InfluxDB setup wizard in the browser
      2. Create an API token in InfluxDB
      3. Add the InfluxDB data source in Grafana
      4. Import the dashboards

.PARAMETER GrafanaVersion
    Grafana version to install. Default: 11.5.2

.EXAMPLE
    .\Setup-MonVM.ps1
#>

param(
    [string]$GrafanaVersion = "11.5.2"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " MON VM Complete Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Install InfluxDB
Write-Host "`n>>> Step 1/3: Installing InfluxDB <<<`n" -ForegroundColor Magenta
& "$scriptDir\Install-InfluxDB.ps1"

# Step 2: Install Grafana
Write-Host "`n>>> Step 2/3: Installing Grafana <<<`n" -ForegroundColor Magenta
& "$scriptDir\Install-Grafana.ps1" -GrafanaVersion $GrafanaVersion

# Step 3: Configure Firewall
Write-Host "`n>>> Step 3/3: Configuring Firewall <<<`n" -ForegroundColor Magenta
& "$scriptDir\Configure-Firewall.ps1"

# Final summary
Write-Host "`n" -ForegroundColor White
Write-Host "========================================================" -ForegroundColor Green
Write-Host " MON VM Setup COMPLETE" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Services running:" -ForegroundColor White
Get-Service influxdb, Grafana -ErrorAction SilentlyContinue | Format-Table Name, Status, DisplayName -AutoSize
Write-Host ""
Write-Host "============== MANUAL STEPS REQUIRED ==============" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. INFLUXDB SETUP (http://localhost:8086):" -ForegroundColor Yellow
Write-Host "   - Username     : admin" -ForegroundColor White
Write-Host "   - Password     : (choose a strong password)" -ForegroundColor White
Write-Host "   - Organization : activeprobe-perf" -ForegroundColor White
Write-Host "   - Bucket       : telegraf" -ForegroundColor White
Write-Host ""
Write-Host "2. CREATE API TOKEN:" -ForegroundColor Yellow
Write-Host "   - In InfluxDB UI: Load Data > API Tokens" -ForegroundColor White
Write-Host "   - Generate API Token > All Access API Token" -ForegroundColor White
Write-Host "   - Name: telegraf-writer" -ForegroundColor White
Write-Host "   - >>> COPY AND SAVE THE TOKEN! <<<" -ForegroundColor Red
Write-Host ""
Write-Host "3. GRAFANA DATA SOURCE (http://localhost:3000):" -ForegroundColor Yellow
Write-Host "   - Login: admin / admin" -ForegroundColor White
Write-Host "   - Connections > Data Sources > Add > InfluxDB" -ForegroundColor White
Write-Host "   - Name: InfluxDB-Perf, Query Language: Flux" -ForegroundColor White
Write-Host "   - URL: http://localhost:8086" -ForegroundColor White
Write-Host "   - Organization: activeprobe-perf" -ForegroundColor White
Write-Host "   - Token: (paste your token)" -ForegroundColor White
Write-Host "   - Default Bucket: telegraf" -ForegroundColor White
Write-Host "   - Click Save & Test" -ForegroundColor White
Write-Host ""
Write-Host "4. IMPORT DASHBOARDS:" -ForegroundColor Yellow
Write-Host "   - Dashboards > Import > ID 22226 (Windows Metrics)" -ForegroundColor White
Write-Host "   - Dashboards > Import > Upload sensor-performance-dashboard.json" -ForegroundColor White
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Yellow
