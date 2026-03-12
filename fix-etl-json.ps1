$raw = Get-Content "c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-data-wetrun4.json" -Raw
$jsonStart = $raw.IndexOf('{')
if ($jsonStart -ge 0) {
    $json = $raw.Substring($jsonStart)
    $json | Set-Content "c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-data-wetrun4.json" -Encoding UTF8
    Write-Host "Fixed: JSON starts at char $jsonStart"
    $data = $json | ConvertFrom-Json
    Write-Host "Traces: $($data.traces.Count)"
    Write-Host "Processes: $($data.traces[0].topProcesses.Count)"
    if ($data.traces[0].topFunctions) { Write-Host "Functions: $($data.traces[0].topFunctions.Count)" }
} else {
    Write-Host "ERROR: No JSON found"
}
