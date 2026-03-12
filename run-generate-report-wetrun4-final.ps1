Set-Location "c:\Users\OmerMunchik\Development\sensor-perf-testing"
.\tools\generate-perf-report.ps1 `
    -SkipInfluxDB `
    -SkipEtl `
    -InfluxJsonPath ".\influx-data-wetrun4.json" `
    -EtlJsonPath ".\etl-data-wetrun4.json" `
    -OutputPath ".\perf-report-wetrun4-20260307.html" `
    -EtlOutputPath ".\perf-report-etl-wetrun4-20260307.html" `
    -NumCores 2
