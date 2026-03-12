$d = Get-Content "c:\Users\OmerMunchik\Development\sensor-perf-testing\influx-data-wetrun4.json" | ConvertFrom-Json
Write-Host "=== Sensor CPU on S2 (V26.1+Phoenix) by scenario ==="
$s2 = @($d.sensorCpu | Where-Object { $_.host -eq "TEST-PERF-S2" } | Sort-Object -Property { [double]$_.peakCpu } -Descending)
foreach ($e in $s2) {
    Write-Host ("  {0,-30} avg={1,6:N1}%  peak={2,6:N1}%" -f $e.scenario, [double]$e.avgCpu, [double]$e.peakCpu)
}
Write-Host ""
Write-Host "=== Worst scenario: $($s2[0].scenario) (peak $([math]::Round([double]$s2[0].peakCpu, 1))%) ==="
