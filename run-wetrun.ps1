<#
.SYNOPSIS
    Robust wet-run orchestrator. Launches tests on all VMs, monitors completion,
    collects data, generates reports. Crash-recoverable via checkpoint files.
.DESCRIPTION
    Phases:
      1. Launch tests on all VMs via SSH (non-blocking)
      2. Poll for completion by counting result files
      3. Fetch InfluxDB data from MON VM
      4. Collect ETL trace from worst scenario
      5. Generate reports (HTML + Confluence)
    
    Recovery: Re-run the script with same -RunId. Reads checkpoint files, skips completed phases.
.PARAMETER RunId
    Unique identifier for this run. Used in file names.
.PARAMETER SkipTests
    Skip phases 1-2 (test launch + monitoring). Use when tests already completed.
.PARAMETER ForceRestart
    Delete checkpoint file and start fresh.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$RunId,
    [switch]$SkipTests,
    [switch]$ForceRestart,
    [switch]$LightMode
)

$ErrorActionPreference = "Continue"

$baseDir = "c:\Users\OmerMunchik\Development\sensor-perf-testing"
$checkpointFile = Join-Path $baseDir "$RunId-checkpoint.json"
$logFile = Join-Path $baseDir "$RunId-log.txt"

$vms = @(
    @{ Name = "S1"; IP = "172.46.17.140"; Hostname = "TEST-PERF-S1"; Role = "No Sensor (Baseline)" }
    @{ Name = "S2"; IP = "172.46.16.179"; Hostname = "TEST-PERF-S2"; Role = "V26.1 + Phoenix" }
    @{ Name = "S3"; IP = "172.46.17.21";  Hostname = "TEST-PERF-S3"; Role = "V26.1 + Legacy" }
    @{ Name = "S4"; IP = "172.46.17.40";  Hostname = "TEST-PERF-S4"; Role = "V24.1 + Legacy" }
)
$monVm = "172.46.16.24"
$influxToken = $env:INFLUXDB_TOKEN
if (-not $influxToken) {
    $influxToken = "TXAx5RsDsBxHqCgaGbeKEZWEHprToZUIEuQ5MfCehnhgv8g-0q836nnw9Y3fF5CN8RxIqJtLNqFS2ZCxkv3dQA=="
}

# ── Helpers ──

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

function Run-SSH {
    param([string]$IP, [string]$Command)
    $tmpOut = Join-Path $env:TEMP "ssh_out_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    $tmpErr = Join-Path $env:TEMP "ssh_err_$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    try {
        $p = Start-Process -FilePath "ssh" -ArgumentList "-o","StrictHostKeyChecking=no","-o","ConnectTimeout=15","admin@$IP",$Command -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $out = ""; if (Test-Path $tmpOut) { $out = (Get-Content $tmpOut -Raw -ErrorAction SilentlyContinue) }
        if (-not $out) { $out = "" }
        return $out.Trim()
    } finally {
        Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

function Save-Checkpoint($phase, $data) {
    $cp = @{}
    if (Test-Path $checkpointFile) {
        try {
            $raw = Get-Content $checkpointFile -Raw | ConvertFrom-Json
            foreach ($prop in $raw.PSObject.Properties) { $cp[$prop.Name] = $prop.Value }
        } catch {}
    }
    $cp[$phase] = [PSCustomObject]$data
    [PSCustomObject]$cp | ConvertTo-Json -Depth 5 | Set-Content $checkpointFile -Encoding UTF8
}

function Get-Checkpoint($phase) {
    if (-not (Test-Path $checkpointFile)) { return $null }
    try {
        $raw = Get-Content $checkpointFile -Raw | ConvertFrom-Json
        if ($raw.PSObject.Properties[$phase]) { return $raw.$phase }
    } catch {}
    return $null
}

function Count-ResultFiles($ip) {
    $todayStr = Get-Date -Format "yyyyMMdd"
    $raw = Run-SSH -IP $ip -Command "cmd /c dir /b C:\PerfTest\results\*$todayStr*.json"
    if (-not $raw -or $raw -match "File Not Found" -or $raw -match "cannot find") { return 0 }
    $lines = @($raw -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    return $lines.Count
}

# ═══════════════════════════════════════════════════

if ($ForceRestart -and (Test-Path $checkpointFile)) {
    Remove-Item $checkpointFile -Force
    Log "Force restart: cleared checkpoint file"
}

Log "═══════════════════════════════════════════════════"
Log " WET-RUN ORCHESTRATOR: $RunId"
Log "═══════════════════════════════════════════════════"

# ── PHASE 1: Launch tests ──

$startTime = Get-Date -Format "o"
$launchCp = Get-Checkpoint "launch"

if ($SkipTests) {
    Log "PHASE 1: SKIPPED (SkipTests)"
    if ($launchCp) { $startTime = $launchCp.startTime }
    else { $startTime = (Get-Date).AddHours(-6).ToString("o") }
}
elseif ($launchCp) {
    Log "PHASE 1: Already launched (checkpoint). Start: $($launchCp.startTime)"
    $startTime = $launchCp.startTime
}
else {
    Log "PHASE 1: Launching tests on all VMs..."
    $startTime = Get-Date -Format "o"

    foreach ($vm in $vms) {
        Log "  Launching $($vm.Name) ($($vm.IP))..."
        $outFile = Join-Path $baseDir "$RunId-$($vm.Name)-stdout.txt"
        $errFile = Join-Path $baseDir "$RunId-$($vm.Name)-stderr.txt"
        $lightFlag = if ($LightMode) { " -LightMode" } else { "" }
        $sshCmd = "cmd /c powershell -ExecutionPolicy Bypass -File C:\PerfTest\test-scenarios\Run-AllScenarios.ps1$lightFlag"
        $p = Start-Process -FilePath "ssh" -ArgumentList "-o","StrictHostKeyChecking=no","-o","ConnectTimeout=15","admin@$($vm.IP)",$sshCmd -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        Log "  $($vm.Name): launched (PID $($p.Id))"
        Start-Sleep -Seconds 3
    }

    Save-Checkpoint "launch" @{ startTime = $startTime; launched = $true }
    Log "All VMs launched."
}

# ── PHASE 2: Monitor completion ──

$completionCp = Get-Checkpoint "completion"

if ($SkipTests) {
    Log "PHASE 2: SKIPPED (SkipTests)"
}
elseif ($completionCp) {
    Log "PHASE 2: Already completed (checkpoint)"
}
else {
    Log "PHASE 2: Monitoring test completion..."
    $maxWait = if ($LightMode) { 120 } else { 240 }
    $poll = 120
    Log "  Expected: 13 scenarios per VM. Mode: $(if ($LightMode) { 'LIGHT' } else { 'FULL' })"
    Log "  Polling every 2 minutes. Max wait: $maxWait min."
    $t0 = Get-Date

    while ($true) {
        $elapsed = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
        if ($elapsed -gt $maxWait) {
            Log "  Max wait exceeded ($maxWait min). Proceeding."
            break
        }

        Start-Sleep -Seconds $poll

        $counts = @{}
        foreach ($vm in $vms) {
            $c = Count-ResultFiles $vm.IP
            $counts[$vm.Name] = $c
        }

        $status = ($vms | ForEach-Object { "$($_.Name):$($counts[$_.Name])" }) -join "  "
        Log "  [$elapsed min] $status"

        $s1Done = $counts["S1"] -ge 13
        $s2Done = $counts["S2"] -ge 13
        $s3Done = $counts["S3"] -ge 13
        $s4Done = $counts["S4"] -ge 13

        if ($s1Done -and $s2Done -and $s3Done -and $s4Done) {
            Log "  All VMs have sufficient results!"
            Log "  Cooling down 2 minutes..."
            Start-Sleep -Seconds 120
            break
        }
    }

    Save-Checkpoint "completion" @{ completedAt = (Get-Date -Format "o"); counts = [PSCustomObject]$counts }
    Log "Phase 2 complete."
}

# ── PHASE 3: Collect InfluxDB data ──

$influxDataPath = Join-Path $baseDir "influx-data-$RunId.json"
$influxCp = Get-Checkpoint "influx"

if ($influxCp -and (Test-Path $influxDataPath)) {
    Log "PHASE 3: Already collected (checkpoint)"
} else {
    Log "PHASE 3: Collecting InfluxDB data..."

    Log "  Copying influx-analyze.ps1 to MON VM..."
    & scp -o StrictHostKeyChecking=no "$baseDir\tools\influx-analyze.ps1" "admin@${monVm}:C:\temp\influx-analyze.ps1"

    $startUtc = ([datetime]::Parse($startTime)).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Log "  Time range start: $startUtc"
    $influxCmd = "cmd /c powershell -ExecutionPolicy Bypass -Command Set-Location C:\temp; .\influx-analyze.ps1 -Token '$influxToken' -InfluxUrl 'http://localhost:8086' -TimeRange '$startUtc' -OutputPath 'C:\temp\influx-data-$RunId.json'"
    Log "  Running influx-analyze.ps1 on MON..."
    $result = Run-SSH -IP $monVm -Command $influxCmd
    Log "  influx-analyze result: $result"

    Log "  Downloading data..."
    & scp -o StrictHostKeyChecking=no "admin@${monVm}:C:\temp\influx-data-$RunId.json" $influxDataPath

    if (Test-Path $influxDataPath) {
        $d = Get-Content $influxDataPath -Raw | ConvertFrom-Json
        $scCount = @($d.sensorCpu | ForEach-Object { $_.scenario } | Sort-Object -Unique).Count
        $hosts = @($d.sensorCpu | ForEach-Object { $_.host } | Sort-Object -Unique) -join ", "
        Log "  Data: sensorCpu=$($d.sensorCpu.Count) procCpu=$($d.systemProcessCpu.Count) procMem=$($d.systemProcessMemory.Count) sysMem=$($d.systemMem.Count)"
        Log "  Scenarios: $scCount  Hosts: $hosts"
        Save-Checkpoint "influx" @{ path = $influxDataPath; scenarios = $scCount }
    } else {
        Log "  ERROR: Failed to download InfluxDB data!"
        throw "InfluxDB data collection failed"
    }
}

# ── PHASE 4: ETL trace ──

$etlDataPath = Join-Path $baseDir "etl-data-$RunId.json"
$etlCp = Get-Checkpoint "etl"

if ($etlCp -and (Test-Path $etlDataPath)) {
    Log "PHASE 4: Already collected (checkpoint)"
} else {
    Log "PHASE 4: Finding worst scenario for ETL..."

    $d = Get-Content $influxDataPath -Raw | ConvertFrom-Json
    $s2Cpu = @($d.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-S2" })
    if ($s2Cpu.Count -eq 0) {
        $s2Cpu = @($d.sensorCpu | Where-Object { $_.host -match "TEST-PERF-(S2|3)" })
    }
    $worst = $s2Cpu | Sort-Object -Property { [double]$_.peakCpu } -Descending | Select-Object -First 1

    if ($worst) {
        $worstScenario = $worst.scenario
        Log "  Worst scenario: $worstScenario (peak CPU $([math]::Round([double]$worst.peakCpu, 1))%)"
    } else {
        $worstScenario = "combined_high_density"
        Log "  No S2 data found, defaulting to $worstScenario"
    }

    Log "  Checking for ETL traces on S2..."
    $traceList = Run-SSH -IP "172.46.16.179" -Command "cmd /c dir /b C:\PerfTest\traces\*.etl"
    $matchingTrace = ""
    if ($traceList -and $traceList -notmatch "File Not Found" -and $traceList -notmatch "cannot find") {
        $matchingTrace = ($traceList -split "`r?`n" | Where-Object { $_ -match $worstScenario } | Select-Object -First 1)
        if ($matchingTrace) { $matchingTrace = $matchingTrace.Trim() }
    }

    if ($matchingTrace -and $matchingTrace.Length -gt 0) {
        Log "  Found trace: $matchingTrace"
        $localEtlDir = Join-Path $baseDir "etl-traces-$RunId"
        if (-not (Test-Path $localEtlDir)) { New-Item -ItemType Directory -Path $localEtlDir -Force | Out-Null }
        & scp -o StrictHostKeyChecking=no "admin@172.46.16.179:C:\PerfTest\traces\$matchingTrace" "$localEtlDir\$matchingTrace"
        Log "  Trace copied locally."

        Log "  Running ETL Analyzer..."
        $etlAnalyzerDir = Join-Path $baseDir "tools\etl-analyzer"
        $symbolPath = Join-Path $baseDir "symbols"
        $dotnetArgs = @("run","--project",$etlAnalyzerDir,"--","--trace",$localEtlDir,"--json")
        if (Test-Path $symbolPath) {
            $pdbDirs = @(Get-ChildItem "$symbolPath\*.pdb" -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
            if ($pdbDirs.Count -gt 0) {
                $dotnetArgs += @("--symbols", ($pdbDirs -join ";"))
            }
        }

        $etlOutput = & dotnet @dotnetArgs 2>&1 | Out-String
        $jsonMatch = [regex]::Match($etlOutput, '\{[\s\S]*"traces"[\s\S]*\}')
        if ($jsonMatch.Success) {
            $jsonMatch.Value | Set-Content $etlDataPath -Encoding UTF8
            Log "  ETL data saved."
        } else {
            Log "  WARNING: No valid JSON from ETL Analyzer. Saving empty."
            '{"traces":[]}' | Set-Content $etlDataPath -Encoding UTF8
        }
    } else {
        Log "  No ETL trace found for $worstScenario (profiling not enabled?)"
        '{"traces":[]}' | Set-Content $etlDataPath -Encoding UTF8
    }

    Save-Checkpoint "etl" @{ path = $etlDataPath; scenario = $worstScenario }
}

# ── PHASE 5: Generate reports ──

Log "PHASE 5: Generating reports..."
$dateStamp = Get-Date -Format "yyyyMMdd"
$mainReport = Join-Path $baseDir "perf-report-$RunId-$dateStamp.html"
$etlReport  = Join-Path $baseDir "perf-report-etl-$RunId-$dateStamp.html"

$reportArgs = @{
    SkipInfluxDB = $true
    SkipEtl = $true
    InfluxJsonPath = $influxDataPath
    EtlJsonPath = $etlDataPath
    OutputPath = $mainReport
    EtlOutputPath = $etlReport
    NumCores = 2
    GenerateConfluence = $true
}
if ($LightMode) { $reportArgs.LightMode = $true }
& "$baseDir\tools\generate-perf-report.ps1" @reportArgs

$confMain = [System.IO.Path]::ChangeExtension($mainReport, "confluence.html")
$confEtl  = [System.IO.Path]::ChangeExtension($etlReport, "confluence.html")

Log ""
Log "════════════════════════════════════════════════"
Log " WET-RUN COMPLETE: $RunId"
Log "════════════════════════════════════════════════"
Log ""
Log "Reports:"
Log "  Main (HTML):       $mainReport"
Log "  Main (Confluence): $confMain"
Log "  ETL  (HTML):       $etlReport"
Log "  ETL  (Confluence): $confEtl"
Log ""
Log "Data:"
Log "  InfluxDB JSON:     $influxDataPath"
Log "  ETL JSON:          $etlDataPath"
Log ""
Log "Recovery files:"
Log "  Log:               $logFile"
Log "  Checkpoint:        $checkpointFile"
Log ""
