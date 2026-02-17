#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Grafana on the MON VM.

.DESCRIPTION
    Downloads the latest Grafana OSS MSI installer and installs it silently.
    Grafana is automatically registered as a Windows service.

.PARAMETER GrafanaVersion
    Version to install. Defaults to 11.5.2.

.NOTES
    Run this script on the MON VM.
    Check https://grafana.com/grafana/download?platform=windows for the latest version.
#>

param(
    [string]$GrafanaVersion = "11.5.2"
)

$ErrorActionPreference = "Stop"

$grafanaUrl = "https://dl.grafana.com/oss/release/grafana-$GrafanaVersion.windows-amd64.msi"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Grafana v$GrafanaVersion Installation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ---------- Check if already installed ----------
$grafanaExe = "C:\Program Files\GrafanaLabs\grafana\bin\grafana-server.exe"
if (Test-Path $grafanaExe) {
    Write-Host "`n[1/3] Grafana already installed, skipping download." -ForegroundColor Yellow
    Write-Host "[2/3] Grafana already installed, skipping install." -ForegroundColor Yellow
}
else {
    # ---------- Step 1: Download ----------
    $msiPath = "$env:TEMP\grafana.msi"
    if (Test-Path $msiPath) {
        Write-Host "`n[1/3] Using previously downloaded MSI..." -ForegroundColor Yellow
    }
    else {
        Write-Host "`n[1/3] Downloading Grafana v$GrafanaVersion..." -ForegroundColor White
        Invoke-WebRequest -Uri $grafanaUrl -OutFile $msiPath -UseBasicParsing
        Write-Host "      Downloaded to $msiPath" -ForegroundColor Gray
    }

    # ---------- Step 2: Install ----------
    Write-Host "[2/3] Installing Grafana (silent)..." -ForegroundColor White
    $installArgs = "/i `"$msiPath`" /quiet /qn /norestart"
    $proc = Start-Process msiexec.exe -ArgumentList $installArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 1603) {
        Write-Host "[ERROR] Grafana installation failed with exit code $($proc.ExitCode)" -ForegroundColor Red
        exit 1
    }
    Write-Host "      Installed successfully." -ForegroundColor Gray
}

# ---------- Step 3: Verify service ----------
Write-Host "[3/3] Verifying Grafana service..." -ForegroundColor White
Start-Sleep -Seconds 5

$svc = Get-Service -Name "Grafana" -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "      Service not found, attempting to start manually..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    $svc = Get-Service -Name "Grafana" -ErrorAction SilentlyContinue
}

if ($svc) {
    if ($svc.Status -ne "Running") {
        Start-Service Grafana
        Start-Sleep -Seconds 3
    }
    Write-Host "`n[OK] Grafana is running!" -ForegroundColor Green
}
else {
    Write-Host "`n[WARN] Grafana service not found. You may need to start it manually." -ForegroundColor Yellow
    Write-Host "       Check: C:\Program Files\GrafanaLabs\grafana\bin\grafana-server.exe" -ForegroundColor Yellow
}

# ---------- Summary ----------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Grafana Installation Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step: Open http://localhost:3000 in your browser" -ForegroundColor Yellow
Write-Host "  Default login: admin / admin" -ForegroundColor White
Write-Host "  (You will be prompted to change the password)" -ForegroundColor White
Write-Host ""
Write-Host "Then add InfluxDB as a data source:" -ForegroundColor Yellow
Write-Host "  1. Go to Connections > Data Sources > Add data source" -ForegroundColor White
Write-Host "  2. Select 'InfluxDB'" -ForegroundColor White
Write-Host "  3. Configure:" -ForegroundColor White
Write-Host "     Name           : InfluxDB-Perf" -ForegroundColor White
Write-Host "     Query Language : Flux" -ForegroundColor White
Write-Host "     URL            : http://localhost:8086" -ForegroundColor White
Write-Host "     Organization   : activeprobe-perf" -ForegroundColor White
Write-Host "     Token          : (paste your telegraf-writer token)" -ForegroundColor White
Write-Host "     Default Bucket : telegraf" -ForegroundColor White
Write-Host "  4. Click 'Save & Test'" -ForegroundColor White
