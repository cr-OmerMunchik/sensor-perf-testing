[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$output = & dotnet run --project "c:\Users\OmerMunchik\Development\sensor-perf-testing\tools\etl-analyzer\EtlAnalyzer.csproj" -- "c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-traces-wetrun4" --symbols --symbol-path "c:\Users\OmerMunchik\Development\activeprobe\ActiveProbe\Win\x64\Release" --scenario service_cycle 2>$null
$jsonLines = @()
$inJson = $false
foreach ($line in $output) {
    if ($line -match '^\s*\{') { $inJson = $true }
    if ($inJson) { $jsonLines += $line }
}
$json = $jsonLines -join [Environment]::NewLine
Set-Content -Path "c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-data-wetrun4.json" -Value $json -Encoding ASCII -NoNewline
Write-Host "JSON written: $($json.Length) chars"
$data = $json | ConvertFrom-Json
Write-Host "Traces: $($data.traces.Count)"
Write-Host "Top processes: $($data.traces[0].topProcesses.Count)"
Write-Host "Top functions: $($data.traces[0].topFunctions.Count)"
Write-Host "First function: $($data.traces[0].topFunctions[0].module) :: $($data.traces[0].topFunctions[0].function)"
