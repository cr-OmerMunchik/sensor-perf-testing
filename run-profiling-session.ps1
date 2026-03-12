Set-Location C:\PerfTest\test-scenarios
.\Run-AllScenarios.ps1 `
    -OnlyScenarios @("file_stress_loop","registry_storm","process_storm","network_burst","combined_high_density") `
    -EnableProfiling `
    -LightMode `
    -PauseBetweenSeconds 20
