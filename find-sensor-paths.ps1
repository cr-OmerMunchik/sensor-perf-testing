$services = @("CybereasonActiveProbe","ActiveConsole","minionhost","CrAmTray","CrAmService","ExecutionPreventionSvc")
foreach ($svc in $services) {
    $reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -ErrorAction SilentlyContinue
    if ($reg -and $reg.ImagePath) {
        Write-Output "SVC|$svc|$($reg.ImagePath)"
    }
}
$sensorDirs = @("C:\Program Files\Cybereason ActiveProbe","C:\ProgramData\Cybereason","C:\Program Files\Cybereason")
foreach ($d in $sensorDirs) {
    if (Test-Path $d) {
        $exes = Get-ChildItem $d -Recurse -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 20
        foreach ($f in $exes) { Write-Output "EXE|$($f.FullName)" }
        $pdbs = Get-ChildItem $d -Recurse -Filter "*.pdb" -ErrorAction SilentlyContinue | Select-Object -First 20
        foreach ($f in $pdbs) { Write-Output "PDB|$($f.FullName)" }
    }
}
