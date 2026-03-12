$proc = Start-Process -FilePath "dotnet" -ArgumentList "run","--project","c:\Users\OmerMunchik\Development\sensor-perf-testing\tools\etl-analyzer\EtlAnalyzer.csproj","--","c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-traces-wetrun4","--symbols","--symbol-path","c:\Users\OmerMunchik\Development\activeprobe\ActiveProbe\Win\x64\Release","--scenario","service_cycle" -RedirectStandardOutput "c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-raw-output.txt" -RedirectStandardError "c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-stderr.txt" -NoNewWindow -Wait -PassThru
Write-Host "Exit code: $($proc.ExitCode)"
$raw = [System.IO.File]::ReadAllText("c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-raw-output.txt")
Write-Host "Raw output length: $($raw.Length)"
Write-Host "First 100 chars: $($raw.Substring(0, [Math]::Min(100, $raw.Length)))"
$jsonStart = $raw.IndexOf('{')
if ($jsonStart -ge 0) {
    $json = $raw.Substring($jsonStart)
    [System.IO.File]::WriteAllText("c:\Users\OmerMunchik\Development\sensor-perf-testing\etl-data-wetrun4.json", $json, [System.Text.UTF8Encoding]::new($false))
    Write-Host "JSON written: $($json.Length) chars"
}
