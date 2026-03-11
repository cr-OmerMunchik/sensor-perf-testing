param(
    [string]$ScenarioFilter = "",
    [string]$TraceDir = "",
    [string]$OutputName = ""
)

$baseDir = $PSScriptRoot
$jenkinsBase = "$baseDir\CybereasonSensor64_26_1_30_1_integration"
$pdbDirs = @(
    "$jenkinsBase\ActiveProbe\Win\x64\Release",
    "$jenkinsBase\NnxSvc\Win\x64\Release",
    "$jenkinsBase\BlockySvc\x64\Release",
    "$jenkinsBase\CrMon\x64\Release",
    "$jenkinsBase\CrsSvc\x64\Release",
    "$jenkinsBase\PoweReason\x64\Release"
)
$symbolPath = ($pdbDirs -join ";") + ";SRV*C:\symbols*https://msdl.microsoft.com/download/symbols"
$env:_NT_SYMBOL_PATH = $symbolPath

if (-not $TraceDir) { $TraceDir = "$baseDir\etl-traces-profiling" }

$sensorMods = @("Nnx","ActiveConsole","minionhost","AmSvc","ExecutionPreventionSvc","CrsSvc","CrAmTray","WscIfSvc","CrDrvCtrl")

Write-Host "Running ETL Analyzer..." -ForegroundColor Cyan
if ($ScenarioFilter) {
    Write-Host "  Scenario filter: $ScenarioFilter"
} else {
    Write-Host "  Scenario filter: (none - processing all traces)"
}
Write-Host "  Trace directory: $TraceDir"
Write-Host "  Symbol path includes $($pdbDirs.Count) PDB directories"

$analyzerArgs = @("$TraceDir", "--symbols", "--symbol-path", $symbolPath, "--top-processes", "25")
if ($ScenarioFilter) {
    $analyzerArgs += @("--scenario", $ScenarioFilter)
}

$rawOutput = & dotnet run --project "$baseDir\tools\etl-analyzer" -- @analyzerArgs 2>&1 | Out-String

$jsonStart = $rawOutput.IndexOf('{')
if ($jsonStart -lt 0) {
    Write-Host "ERROR: No JSON output from analyzer" -ForegroundColor Red
    Write-Host $rawOutput.Substring(0, [Math]::Min(3000, $rawOutput.Length))
    exit 1
}

$jsonStr = $rawOutput.Substring($jsonStart)
$etlJsonPath = "$baseDir\etl-data-profiling-v30.json"
$jsonStr | Set-Content $etlJsonPath -Encoding UTF8
Write-Host "ETL data saved to: $etlJsonPath" -ForegroundColor Green

$parsed = $jsonStr | ConvertFrom-Json

Write-Host "`n=== Traces Found: $($parsed.traces.Count) ===" -ForegroundColor Yellow
foreach ($trace in $parsed.traces) {
    if ($trace.error) {
        Write-Host "  [ERROR] $($trace.traceFile): $($trace.error)" -ForegroundColor Red
        continue
    }
    $scenarioName = $trace.scenario -replace '_TEST-PERF-S\d+(_\d+)?$', ''
    Write-Host "`n--- $scenarioName ---" -ForegroundColor Cyan
    Write-Host "  Samples: $($trace.sampleCount)  |  Weight: $([math]::Round([double]$trace.totalWeightMs / 1000, 1))s"
    foreach ($p in $trace.topProcesses | Select-Object -First 10) {
        $tag = if ($sensorMods -contains $p.process) { " [SENSOR]" } else { "" }
        Write-Host ("    {0}: {1}% ({2}ms){3}" -f $p.process, $p.percent, $p.weightMs, $tag)
    }
    $sensorFuncs = @($trace.topFunctions | Where-Object { $sensorMods -contains $_.module }) | Select-Object -First 5
    if ($sensorFuncs.Count -gt 0) {
        Write-Host "  Top sensor functions:" -ForegroundColor Gray
        foreach ($f in $sensorFuncs) {
            Write-Host ("    {0}!{1} => {2}% ({3}ms)" -f $f.module, $f.function, $f.percent, $f.weightMs)
        }
    }
}

$timestamp = Get-Date -Format "yyyy-MM-dd"
if (-not $OutputName) { $OutputName = "etl-cpu-hotspots-report-$timestamp" }
$etlOutputPath = "$baseDir\reports\$OutputName.html"

New-Item -ItemType Directory -Path "$baseDir\reports" -Force | Out-Null

Write-Host "`nGenerating ETL report..." -ForegroundColor Cyan
& "$baseDir\tools\generate-perf-report.ps1" `
    -SkipInfluxDB -SkipEtl `
    -InfluxJsonPath "$baseDir\influx-data-wetrun8-light.json" `
    -EtlJsonPath $etlJsonPath `
    -OutputPath "$baseDir\perf-report-TEMP-DISCARD.html" `
    -EtlOutputPath $etlOutputPath `
    -NumCores 2 `
    -GenerateConfluence

Remove-Item "$baseDir\perf-report-TEMP-DISCARD.html" -ErrorAction SilentlyContinue
Remove-Item "$baseDir\perf-report-TEMP-DISCARD.confluence.html" -ErrorAction SilentlyContinue

$confPath = [System.IO.Path]::ChangeExtension($etlOutputPath, "confluence.html")
Write-Host "`n=== REPORTS GENERATED ===" -ForegroundColor Green
Write-Host "HTML:       $etlOutputPath"
Write-Host "Confluence: $confPath"
