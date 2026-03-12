Write-Host "=== Cybereason directories ==="
Get-ChildItem "C:\ProgramData" -Directory | Where-Object { $_.Name -match "Cyber|Active|Minion|crs" } | ForEach-Object { $_.FullName }
Get-ChildItem "C:\Program Files" -Directory | Where-Object { $_.Name -match "Cyber|Active" } | ForEach-Object { $_.FullName }

Write-Host "`n=== MySQL services ==="
Get-Service *mysql* -ErrorAction SilentlyContinue | Format-List Name, Status, DisplayName

Write-Host "`n=== MySQL processes ==="
Get-Process *mysql* -ErrorAction SilentlyContinue | Select-Object ProcessName, Id

Write-Host "`n=== Search for .db/.sqlite/.myd/.ibd files ==="
Get-ChildItem "C:\ProgramData" -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '\.(db|sqlite|myd|ibd|frm|myi|cnf)$' } | Select-Object -First 20 FullName, Length

Write-Host "`n=== MySQL data dir (if exists) ==="
$paths = @("C:\ProgramData\MySQL", "C:\ProgramData\Cybereason", "C:\Program Files\Cybereason ActiveProbe")
foreach ($p in $paths) {
    if (Test-Path $p) {
        Write-Host "--- $p ---"
        Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 30 FullName, Length | Format-Table -AutoSize
    }
}
