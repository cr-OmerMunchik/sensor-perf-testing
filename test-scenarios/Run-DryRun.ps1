$ErrorActionPreference = "Continue"
Set-Location C:\PerfTest\test-scenarios

$scenarios = @(
    @{ Name = "idle_baseline";          Script = "Test-IdleBaseline.ps1";          Args = @{ DurationMinutes = 10 } },
    @{ Name = "file_stress_loop";       Script = "Test-FileStressLoop.ps1";        Args = @{ LoopCount = 500; Iterations = 3 } },
    @{ Name = "file_storm";             Script = "Test-FileStorm.ps1";             Args = @{ FileCount = 2000; Bursts = 3 } },
    @{ Name = "process_storm";          Script = "Test-ProcessStorm.ps1";          Args = @{ ProcessCount = 100; Bursts = 3 } },
    @{ Name = "registry_storm";         Script = "Test-RegistryStorm.ps1";         Args = @{ LoopCount = 300; Iterations = 3 } },
    @{ Name = "network_burst";          Script = "Test-NetworkBurst.ps1";          Args = @{ RequestCount = 100; Iterations = 3 } },
    @{ Name = "zip_extraction";         Script = "Test-ZipExtraction.ps1";         Args = @{ FileCount = 5000; Iterations = 2 } },
    @{ Name = "rpc_generation";         Script = "Test-RpcGeneration.ps1";         Args = @{ QueryCount = 150; Iterations = 3 } },
    @{ Name = "service_cycle";          Script = "Test-ServiceCycle.ps1";          Args = @{ Cycles = 5 } },
    @{ Name = "user_account_modify";    Script = "Test-UserAccountModify.ps1";     Args = @{ Cycles = 5 } },
    @{ Name = "driver_load";            Script = "Test-DriverLoad.ps1";            Args = @{ Cycles = 3 } },
    @{ Name = "browser_streaming";      Script = "Test-BrowserStreaming.ps1";      Args = @{ DurationSeconds = 180 } },
    @{ Name = "combined_high_density";  Script = "Test-CombinedHighDensity.ps1";   Args = @{ DurationSeconds = 300; FileLoopCount = 500; RegistryLoopCount = 300; NetworkRequestCount = 100 } }
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " DRY RUN on $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host " Scenarios: $($scenarios.Count)" -ForegroundColor White
Write-Host " Started: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

foreach ($s in $scenarios) {
    $scriptPath = Join-Path $PSScriptRoot $s.Script
    if (-not (Test-Path $scriptPath)) {
        Write-Host "[SKIP] $($s.Name) - script not found: $scriptPath" -ForegroundColor Yellow
        continue
    }
    Write-Host "`n>>> Starting: $($s.Name) <<<" -ForegroundColor Cyan
    try {
        $a = $s.Args
        & $scriptPath @a
    } catch {
        Write-Host "[ERROR] $($s.Name): $_" -ForegroundColor Red
    }
    Write-Host "Pausing 30 seconds before next scenario..." -ForegroundColor Gray
    Start-Sleep -Seconds 30
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " DRY RUN COMPLETE on $env:COMPUTERNAME" -ForegroundColor Green
Write-Host " Finished: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
