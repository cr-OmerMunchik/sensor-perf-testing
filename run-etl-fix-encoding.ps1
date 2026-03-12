[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$output = & dotnet run --project "c:\Users\OmerMunchik\Development\sensor-perf-testing\tools\etl-analyzer\EtlAnalyzer.csproj" -- "c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-traces-wetrun4" --symbols --symbol-path "c:\Users\OmerMunchik\Development\activeprobe\ActiveProbe\Win\x64\Release" --scenario service_cycle 2>$null
$jsonLines = @()
$inJson = $false
foreach ($line in $output) {
    if ("$line".TrimStart().StartsWith('{')) { $inJson = $true }
    if ($inJson) { $jsonLines += "$line" }
}
$json = $jsonLines -join [Environment]::NewLine
$data = $json | ConvertFrom-Json
$finalJson = $data | ConvertTo-Json -Depth 10
$finalJson | Out-File -FilePath "c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-data-wetrun4.json" -Encoding utf8
Write-Host "Written. Traces: $($data.traces.Count) Functions: $($data.traces[0].topFunctions.Count)"
