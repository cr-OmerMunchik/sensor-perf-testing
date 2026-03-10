param(
    [string]$ScenarioFilter = "file_stress_loop_TEST-PERF-S2_20260310_111125"
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

$sensorMods = @("Nnx","ActiveConsole","minionhost","AmSvc","ExecutionPreventionSvc","CrsSvc","CrAmTray","WscIfSvc","CrDrvCtrl")

Write-Host "Running ETL Analyzer..." -ForegroundColor Cyan
Write-Host "  Scenario filter: $ScenarioFilter"
Write-Host "  Symbol path includes $($pdbDirs.Count) PDB directories"

$rawOutput = & dotnet run --project "$baseDir\tools\etl-analyzer" -- "$baseDir\etl-traces-profiling" --symbols --symbol-path $symbolPath --top-processes 25 --scenario $ScenarioFilter 2>&1 | Out-String

$jsonStart = $rawOutput.IndexOf('{')
if ($jsonStart -lt 0) {
    Write-Host "ERROR: No JSON output from analyzer" -ForegroundColor Red
    Write-Host $rawOutput.Substring(0, [Math]::Min(3000, $rawOutput.Length))
    exit 1
}

$jsonStr = $rawOutput.Substring($jsonStart)
$jsonStr | Set-Content "$baseDir\etl-data-profiling-v30.json" -Encoding UTF8
Write-Host "ETL data saved to: $baseDir\etl-data-profiling-v30.json" -ForegroundColor Green

$parsed = $jsonStr | ConvertFrom-Json

Write-Host "`n=== Process Breakdown ===" -ForegroundColor Yellow
foreach ($p in $parsed.traces[0].topProcesses) {
    $tag = if ($sensorMods -contains $p.process) { " [SENSOR]" } else { "" }
    Write-Host ("  {0}: {1}% ({2}ms){3}" -f $p.process, $p.percent, $p.weightMs, $tag)
}

Write-Host "`n=== Sensor Function Hotspots ===" -ForegroundColor Yellow
foreach ($f in $parsed.traces[0].topFunctions) {
    if ($sensorMods -contains $f.module) {
        Write-Host ("  {0}!{1} => {2}% ({3}ms)" -f $f.module, $f.function, $f.percent, $f.weightMs)
    }
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$etlOutputPath = "$baseDir\perf-report-etl-resolved-$timestamp.html"

Write-Host "`nGenerating ETL report..." -ForegroundColor Cyan
& "$baseDir\tools\generate-perf-report.ps1" `
    -SkipInfluxDB -SkipEtl `
    -InfluxJsonPath "$baseDir\influx-data-wetrun8-light.json" `
    -EtlJsonPath "$baseDir\etl-data-profiling-v30.json" `
    -OutputPath "$baseDir\perf-report-TEMP-DISCARD.html" `
    -EtlOutputPath $etlOutputPath `
    -NumCores 2 `
    -GenerateConfluence `
    -LightMode

Remove-Item "$baseDir\perf-report-TEMP-DISCARD.html" -ErrorAction SilentlyContinue
Remove-Item "$baseDir\perf-report-TEMP-DISCARD.confluence.html" -ErrorAction SilentlyContinue

$confPath = [System.IO.Path]::ChangeExtension($etlOutputPath, "confluence.html")
Write-Host "`n=== REPORTS GENERATED ===" -ForegroundColor Green
Write-Host "HTML:       $etlOutputPath"
Write-Host "Confluence: $confPath"
