$env:INFLUXDB_TOKEN = "TXAx5RsDsBxHqCgaGbeKEZWEHprToZUIEuQ5MfCehnhgv8g-0q836nnw9Y3fF5CN8RxIqJtLNqFS2ZCxkv3dQA=="
Set-Location "c:\Users\OmerMunchik\Development\sensor-perf-testing"
.\tools\influx-analyze.ps1 -TimeRange "-8h" -OutputPath ".\influx-data-wetrun4.json"
