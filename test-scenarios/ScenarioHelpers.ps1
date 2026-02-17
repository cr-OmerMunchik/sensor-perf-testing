<#
.SYNOPSIS
    Shared helper functions for all test scenarios.

.DESCRIPTION
    Provides a standard interface for scenario execution:
      - Start-Scenario  : Tags metrics, logs start time
      - Write-ScenarioResult : Outputs results in a consistent format (console + JSON)
      - Complete-Scenario : Logs end time, writes summary

    This module is designed for future LoginVSI integration:
      - Each scenario is a self-contained script with standard parameters
      - Results are output as JSON for machine parsing
      - Entry/exit patterns are consistent for orchestration tooling

.NOTES
    Dot-source this file at the top of each scenario script:
      . "$PSScriptRoot\ScenarioHelpers.ps1"
#>

function Start-Scenario {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Description = ""
    )

    $script:ScenarioName = $Name
    $script:ScenarioStart = Get-Date
    $script:ScenarioResults = @{}

    # Switch Telegraf tag
    $switchScript = Join-Path $PSScriptRoot "Switch-Scenario.ps1"
    if (Test-Path $switchScript) {
        & $switchScript -Scenario $Name
    }

    # Brief settle time for Telegraf to pick up the new tag
    Start-Sleep -Seconds 3

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " Scenario: $Name" -ForegroundColor Cyan
    if ($Description) { Write-Host " $Description" -ForegroundColor Gray }
    Write-Host " Host: $env:COMPUTERNAME" -ForegroundColor White
    Write-Host " Started: $($script:ScenarioStart.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Add-ScenarioMetric {
    param(
        [Parameter(Mandatory)]
        [string]$Key,
        [Parameter(Mandatory)]
        $Value
    )
    $script:ScenarioResults[$Key] = $Value
}

function Complete-Scenario {
    $endTime = Get-Date
    $duration = ($endTime - $script:ScenarioStart).TotalSeconds

    Add-ScenarioMetric -Key "duration_seconds" -Value ([math]::Round($duration, 2))
    Add-ScenarioMetric -Key "host" -Value $env:COMPUTERNAME
    Add-ScenarioMetric -Key "scenario" -Value $script:ScenarioName
    Add-ScenarioMetric -Key "start_time" -Value $script:ScenarioStart.ToString('o')
    Add-ScenarioMetric -Key "end_time" -Value $endTime.ToString('o')

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host " Scenario Complete: $($script:ScenarioName)" -ForegroundColor Green
    Write-Host " Duration: $([math]::Round($duration, 1)) seconds" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Green

    # Print results table
    $script:ScenarioResults.GetEnumerator() | Sort-Object Name | Format-Table Name, Value -AutoSize

    # Save results as JSON for machine parsing (LoginVSI or other orchestrators)
    $resultsDir = "C:\PerfTest\results"
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $jsonFile = "$resultsDir\$($script:ScenarioName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $script:ScenarioResults | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
    Write-Host "Results saved to: $jsonFile" -ForegroundColor Yellow
}
