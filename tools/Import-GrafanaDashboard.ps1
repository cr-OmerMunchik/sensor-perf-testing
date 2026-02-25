<#
.SYNOPSIS
    Import or overwrite a Grafana dashboard via the HTTP API.

.DESCRIPTION
    POSTs the dashboard JSON to Grafana's /api/dashboards/db endpoint with overwrite=true.
    Use a Grafana API key (Admin role) or basic auth.

.PARAMETER GrafanaUrl
    Base URL of Grafana (e.g. http://172.46.16.24:3000).

.PARAMETER DashboardPath
    Path to the dashboard JSON file.

.PARAMETER ApiKey
    Grafana API key. If not set, uses $env:GRAFANA_API_KEY.

.PARAMETER BasicAuth
    Basic auth as "user:password" (e.g. "admin:admin"). Use if no API key.

.PARAMETER DatasourceUid
    Optional. Replace ${DS_INFLUXDB} in the dashboard with this InfluxDB datasource UID.

.EXAMPLE
    $env:GRAFANA_API_KEY = "glsa_xxxx"
    .\tools\Import-GrafanaDashboard.ps1

.EXAMPLE
    .\tools\Import-GrafanaDashboard.ps1 -BasicAuth "admin:admin"
#>
param(
    [string]$GrafanaUrl = "http://172.46.16.24:3000",
    [string]$DashboardPath,
    [string]$ApiKey,
    [string]$BasicAuth,
    [string]$DatasourceUid
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)

if (-not $DashboardPath) {
    $DashboardPath = Join-Path $repoRoot "dashboards\sensor-performance-dashboard.json"
}

if (-not (Test-Path $DashboardPath)) {
    Write-Error "Dashboard file not found: $DashboardPath"
}

# Resolve auth
$auth = $null
if ($ApiKey) {
    $auth = "Bearer $ApiKey"
} elseif ($env:GRAFANA_API_KEY) {
    $auth = "Bearer $env:GRAFANA_API_KEY"
} elseif ($BasicAuth) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($BasicAuth)
    $auth = "Basic $([Convert]::ToBase64String($bytes))"
} else {
    Write-Error "Provide -ApiKey, -BasicAuth 'user:password', or set `$env:GRAFANA_API_KEY"
}

$json = Get-Content $DashboardPath -Raw -Encoding UTF8

if ($DatasourceUid) {
    $json = $json -replace '\$\{DS_INFLUXDB\}', $DatasourceUid
}

# Remove __inputs and __requires (used by UI import; API may reject them)
$dashboard = $json | ConvertFrom-Json
$dashboard.PSObject.Properties.Remove('__inputs')
$dashboard.PSObject.Properties.Remove('__requires')
$dashboardJson = $dashboard | ConvertTo-Json -Depth 100 -Compress

$body = @{
    dashboard = ($dashboardJson | ConvertFrom-Json)
    overwrite = $true
} | ConvertTo-Json -Depth 100

$uri = "$GrafanaUrl/api/dashboards/db"
$headers = @{
    Authorization = $auth
    "Content-Type" = "application/json"
}

Write-Host "Importing dashboard to $uri ..." -ForegroundColor Cyan
try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
    Write-Host "Success. Dashboard: $($response.url)" -ForegroundColor Green
    Write-Host "  UID: $($response.uid)  Version: $($response.version)" -ForegroundColor Gray
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    $reader.BaseStream.Position = 0
    $errBody = $reader.ReadToEnd()
    Write-Error "Import failed ($status): $errBody"
}
