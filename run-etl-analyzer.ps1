$output = & dotnet run --project "c:\Users\OmerMunchik\Development\sensor-perf-testing\tools\etl-analyzer\EtlAnalyzer.csproj" -- "c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-traces-wetrun4" --symbols --symbol-path "c:\Users\OmerMunchik\Development\activeprobe\ActiveProbe\Win\x64\Release" --scenario service_cycle 2>&1
$jsonLines = @()
$inJson = $false
foreach ($line in $output) {
    $s = "$line"
    if ($s.TrimStart().StartsWith('{')) { $inJson = $true }
    if ($inJson) { $jsonLines += $s }
}
$json = $jsonLines -join "`n"
[System.IO.File]::WriteAllText("c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-data-wetrun4.json", $json, [System.Text.Encoding]::UTF8)
Write-Host "ETL data written. JSON size: $($json.Length) chars"
$data = $json | ConvertFrom-Json
Write-Host "Traces: $($data.traces.Count)"
Write-Host "Processes: $($data.traces[0].topProcesses.Count)"
if ($data.traces[0].topFunctions) { Write-Host "Functions: $($data.traces[0].topFunctions.Count)" }
