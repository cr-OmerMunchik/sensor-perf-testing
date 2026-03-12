$d = Get-Content "c:\Users\OmerMunchik\Development\sensor-perf-testing\influx-data-wetrun4.json" | ConvertFrom-Json
Write-Host "sensorCpu:" $d.sensorCpu.Count
Write-Host "systemProcessCpu:" $d.systemProcessCpu.Count
Write-Host "systemProcessMemory:" $d.systemProcessMemory.Count
Write-Host "systemCpu:" $d.systemCpu.Count
Write-Host "sensorMemory:" $d.sensorMemory.Count
$scenarios = @($d.sensorCpu | ForEach-Object { $_.scenario } | Sort-Object -Unique)
Write-Host "scenarios:" $scenarios.Count
$scenarios | ForEach-Object { Write-Host "  $_" }
if ($d.systemProcessMemory.Count -gt 0) {
    Write-Host "`nsample process memory entry:"
    $d.systemProcessMemory[0] | Format-List
}
