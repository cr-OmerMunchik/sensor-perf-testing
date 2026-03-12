<#
.SYNOPSIS
    Robust wet-run orchestrator. Launches tests on all VMs, monitors completion,
    collects data, generates reports. Crash-recoverable via checkpoint files.
.DESCRIPTION
    Phases:
      1. Launch tests on all VMs via SSH
      2. Poll for completion (writes checkpoint after each phase)
      3. Fetch InfluxDB data from MON VM
      4. Collect ETL trace from worst scenario
      5. Generate reports (HTML + Confluence)
    
    Recovery: Re-run the script. It reads checkpoint files and skips completed phases.
#>
param(
    [string]$RunId = "wetrun5",
    [switch]$SkipTests,
    [switch]$ForceRestart
)

$ErrorActionPreference = "Stop"

$baseDir = "c:\Users\OmerMunchik\Development\sensor-perf-testing"
$checkpointFile = Join-Path $baseDir "$RunId-checkpoint.json"
$logFile = Join-Path $baseDir "$RunId-log.txt"

$vms = @(
    @{ Name = "S1"; Host = "172.46.17.140"; Hostname = "TEST-PERF-S1"; Role = "No Sensor (Baseline)" }
    @{ Name = "S2"; Host = "172.46.16.179"; Hostname = "TEST-PERF-S2"; Role = "V26.1 + Phoenix" }
    @{ Name = "S3"; Host = "172.46.17.21";  Hostname = "TEST-PERF-S3"; Role = "V26.1 + Legacy" }
    @{ Name = "S4"; Host = "172.46.17.40";  Hostname = "TEST-PERF-S4"; Role = "V24.1 + Legacy" }
)
$monVm = "172.46.16.24"
$influxToken = "TXAx5RsDsBxHqCgaGbeKEZWEHprToZUIEuQ5MfCehnhgv8g-0q836nnw9Y3fF5CN8RxIqJtLNqFS2ZCxkv3dQA=="
$allScenarios = @("idle_baseline","registry_storm","network_burst","process_storm","rpc_generation","service_cycle","user_account_modify","browser_streaming","driver_load","file_stress_loop","zip_extraction","file_storm","combined_high_density")

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

function Save-Checkpoint($phase, $data) {
    $cp = @{}
    if (Test-Path $checkpointFile) {
        try {
            $raw = Get-Content $checkpointFile -Raw | ConvertFrom-Json
            foreach ($prop in $raw.PSObject.Properties) { $cp[$prop.Name] = $prop.Value }
        } catch { $cp = @{} }
    }
    $cp[$phase] = [PSCustomObject]$data
    [PSCustomObject]$cp | ConvertTo-Json -Depth 5 | Set-Content $checkpointFile -Encoding UTF8
    Log "Checkpoint saved: $phase"
}

function Get-Checkpoint($phase) {
    if (-not (Test-Path $checkpointFile)) { return $null }
    try {
        $raw = Get-Content $checkpointFile -Raw | ConvertFrom-Json
        if ($raw.PSObject.Properties[$phase]) { return $raw.$phase }
    } catch {}
    return $null
}

function Invoke-SSH($ip, $cmd) {
    $allArgs = @("-o","StrictHostKeyChecking=no","-o","ConnectTimeout=10","-o","BatchMode=yes","admin@$ip") + @($cmd)
    $proc = Start-Process ssh -ArgumentList $allArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$env:TEMP\ssh-out.txt" -RedirectStandardError "$env:TEMP\ssh-err.txt"
    $output = ""
    if (Test-Path "$env:TEMP\ssh-out.txt") { $output = Get-Content "$env:TEMP\ssh-out.txt" -Raw }
    return $output.Trim()
}

# ═══════════════════════════════════════════════════
# PHASE 1: Launch tests on all VMs
# ═══════════════════════════════════════════════════
$startTime = Get-Date -Format "o"

if ($ForceRestart) {
    if (Test-Path $checkpointFile) { Remove-Item $checkpointFile -Force }
    Log "Force restart: cleared checkpoints"
}

$launchCp = Get-Checkpoint "launch"
if ($launchCp -and -not $SkipTests) {
    Log "PHASE 1: Tests already launched (from checkpoint). Start time: $($launchCp.startTime)"
    $startTime = $launchCp.startTime
} elseif (-not $SkipTests) {
    Log "PHASE 1: Launching tests on all VMs..."
    $startTime = Get-Date -Format "o"

    foreach ($vm in $vms) {
        Log "  Launching on $($vm.Name) ($($vm.Host))..."
        $sshCmd = "cmd /c powershell -ExecutionPolicy Bypass -File C:\PerfTest\test-scenarios\Run-AllScenarios.ps1"
        $proc = Start-Process ssh -ArgumentList "-o","StrictHostKeyChecking=no","-o","ConnectTimeout=10","admin@$($vm.Host)",$sshCmd -NoNewWindow -PassThru -RedirectStandardOutput "$baseDir\$RunId-$($vm.Name)-stdout.txt" -RedirectStandardError "$baseDir\$RunId-$($vm.Name)-stderr.txt"
        Log "  $($vm.Name): PID $($proc.Id)"
        Start-Sleep -Seconds 2
    }

    Save-Checkpoint "launch" @{ startTime = $startTime; launched = $true }
    Log "All VMs launched. Monitoring for completion..."
} else {
    Log "PHASE 1: Skipped (SkipTests flag)"
    $startTime = (Get-Date).AddHours(-8).ToString("o")
}

# ═══════════════════════════════════════════════════
# PHASE 2: Monitor completion
# ═══════════════════════════════════════════════════
$completionCp = Get-Checkpoint "completion"
if ($completionCp) {
    Log "PHASE 2: Already completed (from checkpoint)"
} elseif (-not $SkipTests) {
    Log "PHASE 2: Monitoring test completion on all VMs..."
    $maxWaitMinutes = 240
    $pollIntervalSeconds = 60
    $startWait = Get-Date

    while ($true) {
        $elapsed = ((Get-Date) - $startWait).TotalMinutes
        if ($elapsed -gt $maxWaitMinutes) {
            Log "WARNING: Max wait time ($maxWaitMinutes min) exceeded. Proceeding with available data."
            break
        }

        $allDone = $true
        $statusLines = @()
        $todayStr = Get-Date -Format "yyyyMMdd"
        foreach ($vm in $vms) {
            $resultFiles = Invoke-SSH $vm.Host "cmd /c dir /b C:\PerfTest\results\*$todayStr*.json"
            $files = @($resultFiles -split "`r`n" | Where-Object { $_.Trim() -ne "" -and $_ -notmatch "File Not Found" -and $_ -notmatch "cannot find" })
            $count = $files.Count

            $statusLines += "    $($vm.Name): $count/13 scenarios"
            if ($count -lt 6) { $allDone = $false }
        }

        Log "  Status after $([math]::Round($elapsed, 1)) min:"
        foreach ($sl in $statusLines) { Log $sl }

        if ($allDone) {
            Log "  All VMs have sufficient results. Waiting 2 min for final cooldown..."
            Start-Sleep -Seconds 120
            break
        }

        Log "  Waiting $pollIntervalSeconds seconds..."
        Start-Sleep -Seconds $pollIntervalSeconds
    }

    Save-Checkpoint "completion" @{ completedAt = (Get-Date -Format "o") }
} else {
    Log "PHASE 2: Skipped (SkipTests flag)"
}

# ═══════════════════════════════════════════════════
# PHASE 3: Collect InfluxDB data
# ═══════════════════════════════════════════════════
$influxDataPath = Join-Path $baseDir "influx-data-$RunId.json"
$influxCp = Get-Checkpoint "influx"
if ($influxCp -and (Test-Path $influxDataPath)) {
    Log "PHASE 3: InfluxDB data already collected (from checkpoint)"
} else {
    Log "PHASE 3: Collecting InfluxDB data from MON VM..."

    scp -o StrictHostKeyChecking=no "$baseDir\tools\influx-analyze.ps1" "admin@${monVm}:C:\temp\influx-analyze.ps1"
    Log "  Copied influx-analyze.ps1 to MON VM"

    $startTimeUtc = ([datetime]::Parse($startTime)).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $influxCmd = "cmd /c powershell -ExecutionPolicy Bypass -Command Set-Location C:\temp; .\influx-analyze.ps1 -Token '$influxToken' -InfluxUrl 'http://localhost:8086' -TimeRange '$startTimeUtc' -OutputPath 'C:\temp\influx-data-$RunId.json'"
    Log "  Running influx-analyze.ps1 on MON VM (TimeRange: $startTimeUtc)..."
    $influxResult = Invoke-SSH $monVm $influxCmd
    Log "  Result: $influxResult"

    scp -o StrictHostKeyChecking=no "admin@${monVm}:C:\temp\influx-data-$RunId.json" $influxDataPath
    Log "  InfluxDB data saved to $influxDataPath"

    $d = Get-Content $influxDataPath -Raw | ConvertFrom-Json
    Log "  Data check: sensorCpu=$($d.sensorCpu.Count) systemProcessCpu=$($d.systemProcessCpu.Count) systemProcessMemory=$($d.systemProcessMemory.Count) systemMem=$($d.systemMem.Count)"
    $scenarios = @($d.sensorCpu | ForEach-Object { $_.scenario } | Sort-Object -Unique)
    Log "  Scenarios found: $($scenarios.Count) ($($scenarios -join ', '))"

    Save-Checkpoint "influx" @{ path = $influxDataPath; scenarios = $scenarios.Count }
}

# ═══════════════════════════════════════════════════
# PHASE 4: Find worst scenario & collect ETL trace
# ═══════════════════════════════════════════════════
$etlDataPath = Join-Path $baseDir "etl-data-$RunId.json"
$etlCp = Get-Checkpoint "etl"
if ($etlCp -and (Test-Path $etlDataPath)) {
    Log "PHASE 4: ETL data already collected (from checkpoint)"
} else {
    Log "PHASE 4: Finding worst scenario for ETL analysis..."

    $d = Get-Content $influxDataPath -Raw | ConvertFrom-Json
    $s2Cpu = @($d.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-S2" -or $_.host -eq "TEST-PERF-3" })
    $worst = $s2Cpu | Sort-Object -Property { [double]$_.peakCpu } -Descending | Select-Object -First 1
    if (-not $worst) {
        $worst = @{ scenario = "combined_high_density" }
        Log "  No S2 CPU data found, defaulting to combined_high_density"
    }
    $worstScenario = $worst.scenario
    Log "  Worst scenario: $worstScenario (peak CPU: $([math]::Round([double]$worst.peakCpu, 1))%)"

    Log "  Checking for ETL trace on S2..."
    $traceList = Invoke-SSH "172.46.16.179" "cmd /c dir /b C:\PerfTest\traces\*.etl"
    $matchingTrace = ($traceList -split "`n" | Where-Object { $_ -match $worstScenario } | Select-Object -First 1).Trim()

    if ($matchingTrace -and $matchingTrace -ne "" -and $matchingTrace -notmatch "File Not Found") {
        Log "  Found ETL trace: $matchingTrace"
        $localEtlDir = Join-Path $baseDir "etl-traces-$RunId"
        if (-not (Test-Path $localEtlDir)) { New-Item -ItemType Directory -Path $localEtlDir -Force | Out-Null }
        scp -o StrictHostKeyChecking=no "admin@172.46.16.179:C:\PerfTest\traces\$matchingTrace" "$localEtlDir\$matchingTrace"
        Log "  ETL trace copied to $localEtlDir\$matchingTrace"

        Log "  Running ETL Analyzer..."
        $etlAnalyzerDir = "c:\Users\OmerMunchik\Development\sensor-perf-testing\tools\EtlAnalyzer"
        $symbolPath = "c:\Users\OmerMunchik\Development\sensor-perf-testing\symbols"
        $pdbPaths = @()
        if (Test-Path $symbolPath) {
            $pdbPaths = @(Get-ChildItem "$symbolPath\*.pdb" -Recurse | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
        }
        $symbolArg = if ($pdbPaths.Count -gt 0) { "--symbols $($pdbPaths -join ';')" } else { "" }

        $etlOutput = & dotnet run --project $etlAnalyzerDir -- --trace $localEtlDir $symbolArg --json 2>&1 | Out-String
        $jsonMatch = [regex]::Match($etlOutput, '\{[\s\S]*"traces"[\s\S]*\}')
        if ($jsonMatch.Success) {
            $jsonMatch.Value | Set-Content $etlDataPath -Encoding UTF8
            Log "  ETL data saved to $etlDataPath"
        } else {
            Log "  WARNING: Could not extract JSON from ETL Analyzer output"
            '{"traces":[]}' | Set-Content $etlDataPath -Encoding UTF8
        }
    } else {
        Log "  No ETL trace found for $worstScenario. Running without ETL profiling."
        Log "  To get ETL data, re-run tests with -EnableProfiling on S2"
        '{"traces":[]}' | Set-Content $etlDataPath -Encoding UTF8
    }

    Save-Checkpoint "etl" @{ path = $etlDataPath; scenario = $worstScenario }
}

# ═══════════════════════════════════════════════════
# PHASE 5: Generate reports
# ═══════════════════════════════════════════════════
Log "PHASE 5: Generating reports..."
$dateStamp = Get-Date -Format "yyyyMMdd"
$mainReportPath = Join-Path $baseDir "perf-report-$RunId-$dateStamp.html"
$etlReportPath = Join-Path $baseDir "perf-report-etl-$RunId-$dateStamp.html"

& "$baseDir\tools\generate-perf-report.ps1" `
    -SkipInfluxDB `
    -SkipEtl `
    -InfluxJsonPath $influxDataPath `
    -EtlJsonPath $etlDataPath `
    -OutputPath $mainReportPath `
    -EtlOutputPath $etlReportPath `
    -NumCores 2 `
    -GenerateConfluence

Log ""
Log "════════════════════════════════════════════════"
Log " WET-RUN COMPLETE: $RunId"
Log "════════════════════════════════════════════════"
Log "Reports:"
Log "  Main (HTML):       $mainReportPath"
Log "  Main (Confluence): $([System.IO.Path]::ChangeExtension($mainReportPath, 'confluence.html'))"
Log "  ETL (HTML):        $etlReportPath"
Log "  ETL (Confluence):  $([System.IO.Path]::ChangeExtension($etlReportPath, 'confluence.html'))"
Log "  InfluxDB data:     $influxDataPath"
Log "  ETL data:          $etlDataPath"
Log "  Log:               $logFile"
Log "  Checkpoint:        $checkpointFile"
Log ""
