#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bootstraps a fresh Windows VM with prerequisites for sensor performance testing.

.DESCRIPTION
    Installs and configures:
    - OpenSSH Server (with PowerShell as default shell)
    - .NET SDK 8.0 (for ETL analyzer)
    - Windows Performance Toolkit (for WPR/ETL profiling)

    This script is intended to run on a freshly provisioned VM from a standard
    BBTest template (which has WinRM but not SSH). It can be invoked via WinRM
    from the Jenkins pipeline, or run manually.

    Once the BB_Win11_x64_23H2_Performance template is available, this script
    becomes unnecessary (but can be kept as a fallback).

.PARAMETER SkipSSH
    Skip OpenSSH Server installation (if already present).

.PARAMETER SkipDotNet
    Skip .NET SDK 8 installation (if already present).

.PARAMETER SkipWPT
    Skip Windows Performance Toolkit installation (if already present).

.EXAMPLE
    .\Bootstrap-VM.ps1

.EXAMPLE
    .\Bootstrap-VM.ps1 -SkipWPT
#>
param(
    [switch]$SkipSSH,
    [switch]$SkipDotNet,
    [switch]$SkipWPT
)

$ErrorActionPreference = "Continue"

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

# --- OpenSSH Server ---
if (-not $SkipSSH) {
    Write-Step "Installing OpenSSH Server"

    $sshCapability = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' }
    if ($sshCapability.State -eq 'Installed') {
        Write-Host "[OK] OpenSSH Server already installed"
    } else {
        Write-Host "[INFO] Installing via Add-WindowsCapability..."
        $result = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction SilentlyContinue
        if (-not $result -or $result.RestartNeeded) {
            Write-Host "[INFO] Capability method may have failed, trying winget..."
            winget install "openssh beta" --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
        }
    }

    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue

    New-NetFirewallRule -Name 'sshd' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
        -ErrorAction SilentlyContinue | Out-Null

    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
        -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null

    $sshdService = Get-Service sshd -ErrorAction SilentlyContinue
    if ($sshdService -and $sshdService.Status -eq 'Running') {
        Write-Host "[OK] SSH Server is running" -ForegroundColor Green
    } else {
        Write-Host "[WARN] SSH Server may not be running" -ForegroundColor Yellow
    }
}

# --- .NET SDK 8 ---
if (-not $SkipDotNet) {
    Write-Step "Installing .NET SDK 8"

    $dotnetVersion = dotnet --version 2>$null
    if ($dotnetVersion -and $dotnetVersion.StartsWith('8.')) {
        Write-Host "[OK] .NET SDK 8 already installed: $dotnetVersion"
    } else {
        Write-Host "[INFO] Installing via winget..."
        winget install Microsoft.DotNet.SDK.8 --accept-package-agreements --accept-source-agreements --silent 2>&1

        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + $env:PATH
        $newVersion = dotnet --version 2>$null
        if ($newVersion) {
            Write-Host "[OK] .NET SDK installed: $newVersion" -ForegroundColor Green
        } else {
            Write-Host "[WARN] .NET SDK may not be on PATH yet (may need new shell)" -ForegroundColor Yellow
        }
    }
}

# --- Windows Performance Toolkit ---
if (-not $SkipWPT) {
    Write-Step "Installing Windows Performance Toolkit"

    $wprPath = Get-Command wpr.exe -ErrorAction SilentlyContinue
    if ($wprPath) {
        Write-Host "[OK] WPR already available at: $($wprPath.Source)"
    } else {
        $adkInstallerUrl = "https://go.microsoft.com/fwlink/?linkid=2271337"
        $adkInstaller = "$env:TEMP\adksetup.exe"

        if (-not (Test-Path $adkInstaller)) {
            Write-Host "[INFO] Downloading ADK installer..."
            Invoke-WebRequest -Uri $adkInstallerUrl -OutFile $adkInstaller -UseBasicParsing
        }

        Write-Host "[INFO] Installing Windows Performance Toolkit (this may take several minutes)..."
        $proc = Start-Process -FilePath $adkInstaller `
            -ArgumentList '/features OptionId.WindowsPerformanceToolkit /quiet /norestart' `
            -Wait -PassThru -NoNewWindow
        Write-Host "[INFO] ADK installer exit code: $($proc.ExitCode)"

        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + $env:PATH
        $wprCheck = Get-Command wpr.exe -ErrorAction SilentlyContinue
        if ($wprCheck) {
            Write-Host "[OK] WPR installed at: $($wprCheck.Source)" -ForegroundColor Green
        } else {
            Write-Host "[WARN] WPR not found on PATH after install (standard path: C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit)" -ForegroundColor Yellow
        }
    }
}

# --- Create working directories ---
Write-Step "Creating working directories"
@('C:\PerfTest\reports', 'C:\PerfTest\results', 'C:\PerfTest\logs', 'C:\sensor') | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-Host "  Created: $_"
    }
}

Write-Step "Bootstrap Complete"
Write-Host "[OK] VM is ready for performance testing" -ForegroundColor Green
