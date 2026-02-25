<#
.SYNOPSIS
    Queries InfluxDB for sensor performance metrics and outputs findings as JSON.
.DESCRIPTION
    Calls InfluxDB HTTP API with Flux queries.
.PARAMETER Token
    InfluxDB API token.
.PARAMETER InfluxUrl
    InfluxDB base URL (default: http://172.46.16.24:8086). On MON VM use http://localhost:8086.
.PARAMETER TimeRange
    Flux time range (default: -7d).
.PARAMETER OutputPath
    Path to write JSON output.

.PARAMETER DebugDumpCsv
    When set, also writes raw CSV for win_cpu/win_mem to .csv files (for diagnosing N/A values).
#>

[CmdletBinding()]
param(
    [string]$Token = $env:INFLUXDB_TOKEN,
    [string]$InfluxUrl = "http://172.46.16.24:8086",
    [string]$TimeRange = "-7d",
    [string]$OutputPath,
    [switch]$DebugDumpCsv
)

$ErrorActionPreference = "Stop"
$tr = $TimeRange

if (-not $Token) { Write-Error "InfluxDB token required." }

$queryUrl = "$InfluxUrl/api/v2/query?org=activeprobe-perf"
$headers = @{ "Authorization" = "Token $Token"; "Accept" = "application/csv"; "Content-Type" = "application/vnd.flux" }

function Invoke-InfluxQuery { param([string]$Query)
    try {
        $r = Invoke-WebRequest -Uri $queryUrl -Method Post -Headers $headers -Body $Query -ContentType "application/vnd.flux" -UseBasicParsing
        return $r.Content
    } catch { Write-Warning "Query failed: $_"; return $null }
}

function Parse-Csv { param([string]$txt)
    $out = @(); $h = $null
    foreach ($line in ($txt -split "`n")) {
        if ($line.StartsWith("#")) { continue }
        $p = $line -split ","
        if ($p.Count -lt 2) { continue }
        $a = $p[0]; $b = $p[1]
        if ($p[0] -eq "" -and $p.Count -ge 3) { $a = $p[1]; $b = $p[2] }
        if ($a -eq "result" -and $b -eq "table") { $h = $p; continue }
        if (-not $h -or $p.Count -lt $h.Count) { continue }
        $o = [ordered]@{}
        for ($i = 0; $i -lt [Math]::Min($h.Count, $p.Count); $i++) {
            $k = $h[$i]; if ($k) { $o[$k] = $p[$i] }
        }
        if ($o.Count -gt 0) {
            $obj = [PSCustomObject]$o
            if ($obj.PSObject.Properties['_value']) {
                $v = $obj._value
                $d = 0.0
                if ([double]::TryParse([string]$v, [ref]$d) -and $d -eq 0) {
                    for ($j = $p.Count - 1; $j -ge 0; $j--) {
                        $tryVal = $p[$j]
                        if ([double]::TryParse([string]$tryVal, [ref]$d) -and $d -gt 0) {
                            $obj | Add-Member -NotePropertyName '_value' -NotePropertyValue $tryVal -Force
                            break
                        }
                    }
                }
            }
            $out += $obj
        }
    }
    return $out
}

$findings = [ordered]@{ timestamp = (Get-Date -Format "o"); timeRange = $tr; sensorCpu = @(); sensorMemory = @(); systemCpu = @(); systemMem = @(); diskIo = @(); kpiFailures = @(); sensorDeltas = @() }

# Sensor CPU: sum across processes at each timestamp, then avg/max over time
$cpuQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> group(columns: [`"_time`", `"host`", `"scenario`"]) |> sum() |> group(columns: [`"host`", `"scenario`"]) |> mean() |> group() |> yield(name: `"avg`")"
$peakQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> group(columns: [`"_time`", `"host`", `"scenario`"]) |> sum() |> group(columns: [`"host`", `"scenario`"]) |> max() |> group() |> yield(name: `"peak`")"
$avgCpu = Parse-Csv (Invoke-InfluxQuery $cpuQ)
$peakCpu = Parse-Csv (Invoke-InfluxQuery $peakQ)
$cpuMap = @{}
foreach ($r in $avgCpu) { $k = "$($r.host)|$($r.scenario)"; $cpuMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; avgCpu = [double]($r._value); peakCpu = 0 } }
foreach ($r in $peakCpu) { $k = "$($r.host)|$($r.scenario)"; if ($cpuMap[$k]) { $cpuMap[$k].peakCpu = [double]($r._value) } }
$findings.sensorCpu = @($cpuMap.Values)

$memQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Working_Set`") |> group(columns: [`"host`", `"scenario`"]) |> sum() |> map(fn: (r) => ({ r with _value: r._value / 1048576.0 })) |> group() |> yield(name: `"mem`")"
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $memQ))) { $findings.sensorMemory += [ordered]@{ host = $r.host; scenario = $r.scenario; avgMemMB = [double]($r._value) } }

foreach ($c in $findings.sensorCpu) { if ($c.peakCpu -gt 15) { $findings.kpiFailures += [ordered]@{ type = "cpu"; host = $c.host; scenario = $c.scenario; value = $c.peakCpu; threshold = 15 } } }
foreach ($m in $findings.sensorMemory) { if ($m.avgMemMB -gt 500) { $findings.kpiFailures += [ordered]@{ type = "memory"; host = $m.host; scenario = $m.scenario; value = $m.avgMemMB; threshold = 500 } } }

$sysCpuAvgQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> filter(fn: (r) => r.instance == `"_Total`") |> group(columns: [`"host`", `"scenario`"]) |> mean() |> group() |> yield(name: `"sys`")"
$sysCpuPeakQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> filter(fn: (r) => r.instance == `"_Total`") |> group(columns: [`"host`", `"scenario`"]) |> max() |> group() |> yield(name: `"sys`")"
$sysCpuAvg = Parse-Csv (Invoke-InfluxQuery $sysCpuAvgQ)
$sysCpuPeak = Parse-Csv (Invoke-InfluxQuery $sysCpuPeakQ)
$sysCpuMap = @{}
foreach ($r in $sysCpuAvg) { $k = "$($r.host)|$($r.scenario)"; $sysCpuMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; avgCpu = [double]($r._value); peakCpu = 0 } }
foreach ($r in $sysCpuPeak) { $k = "$($r.host)|$($r.scenario)"; if ($sysCpuMap[$k]) { $sysCpuMap[$k].peakCpu = [double]($r._value) } }
$findings.systemCpu = @($sysCpuMap.Values)
$sysCpuFallbackAvg = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> filter(fn: (r) => r.instance == `"_Total`") |> group(columns: [`"host`"]) |> last() |> group() |> yield(name: `"sys`")"
$sysCpuFallbackPeak = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> filter(fn: (r) => r.instance == `"_Total`") |> group(columns: [`"host`"]) |> max() |> group() |> yield(name: `"sys`")"
$hostCpuAvg = @{}; foreach ($r in (Parse-Csv (Invoke-InfluxQuery $sysCpuFallbackAvg))) { $hostCpuAvg[$r.host] = [double]($r._value) }
$hostCpuPeak = @{}; foreach ($r in (Parse-Csv (Invoke-InfluxQuery $sysCpuFallbackPeak))) { $hostCpuPeak[$r.host] = [double]($r._value) }
foreach ($e in $findings.systemCpu) {
    if ($e.avgCpu -eq 0 -and $hostCpuAvg[$e.host] -gt 0) { $e.avgCpu = $hostCpuAvg[$e.host] }
    if ($e.peakCpu -eq 0 -and $hostCpuPeak[$e.host] -gt 0) { $e.peakCpu = $hostCpuPeak[$e.host] }
}

$sysMemAvgQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_mem`") |> filter(fn: (r) => r._field == `"Available_MBytes`") |> group(columns: [`"host`", `"scenario`"]) |> mean() |> group() |> yield(name: `"avail`")"
$sysMemPeakQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_mem`") |> filter(fn: (r) => r._field == `"Available_MBytes`") |> group(columns: [`"host`", `"scenario`"]) |> max() |> group() |> yield(name: `"avail`")"
$sysMemAvg = Parse-Csv (Invoke-InfluxQuery $sysMemAvgQ)
$sysMemPeak = Parse-Csv (Invoke-InfluxQuery $sysMemPeakQ)
$sysMemMap = @{}
foreach ($r in $sysMemAvg) { $k = "$($r.host)|$($r.scenario)"; $sysMemMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; avgAvailableMB = [double]($r._value); peakAvailableMB = 0 } }
foreach ($r in $sysMemPeak) { $k = "$($r.host)|$($r.scenario)"; if ($sysMemMap[$k]) { $sysMemMap[$k].peakAvailableMB = [double]($r._value) } }
$findings.systemMem = @($sysMemMap.Values)
$sysMemFallbackAvg = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_mem`") |> filter(fn: (r) => r._field == `"Available_MBytes`") |> group(columns: [`"host`"]) |> last() |> group() |> yield(name: `"avail`")"
$sysMemFallbackPeak = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_mem`") |> filter(fn: (r) => r._field == `"Available_MBytes`") |> group(columns: [`"host`"]) |> max() |> group() |> yield(name: `"avail`")"
$hostMemAvg = @{}; foreach ($r in (Parse-Csv (Invoke-InfluxQuery $sysMemFallbackAvg))) { $hostMemAvg[$r.host] = [double]($r._value) }
$hostMemPeak = @{}; foreach ($r in (Parse-Csv (Invoke-InfluxQuery $sysMemFallbackPeak))) { $hostMemPeak[$r.host] = [double]($r._value) }
foreach ($e in $findings.systemMem) {
    if ($e.avgAvailableMB -eq 0 -and $hostMemAvg[$e.host] -gt 0) { $e.avgAvailableMB = $hostMemAvg[$e.host] }
    if ($e.peakAvailableMB -eq 0 -and $hostMemPeak[$e.host] -gt 0) { $e.peakAvailableMB = $hostMemPeak[$e.host] }
}

$sHost = "TEST-PERF-3"; $nHost = "TEST-PERF-4"
foreach ($sc in ($findings.sensorCpu | ForEach-Object { $_.scenario } | Select-Object -Unique)) {
    $sCpu = $findings.sensorCpu | Where-Object { $_.host -eq $sHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $nCpu = $findings.sensorCpu | Where-Object { $_.host -eq $nHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $sMem = $findings.sensorMemory | Where-Object { $_.host -eq $sHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $nMem = $findings.sensorMemory | Where-Object { $_.host -eq $nHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $sDisk = $findings.diskIo | Where-Object { $_.host -eq $sHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $nDisk = $findings.diskIo | Where-Object { $_.host -eq $nHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $sSysCpu = $findings.systemCpu | Where-Object { $_.host -eq $sHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $nSysCpu = $findings.systemCpu | Where-Object { $_.host -eq $nHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $sSysMem = $findings.systemMem | Where-Object { $_.host -eq $sHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $nSysMem = $findings.systemMem | Where-Object { $_.host -eq $nHost -and $_.scenario -eq $sc } | Select-Object -First 1
    $d = [ordered]@{ scenario = $sc; cpuDelta = 0; sensorCpu = 0; noSensorCpu = 0; memDeltaMB = 0; diskReadDeltaBps = 0; diskWriteDeltaBps = 0; sysCpuDelta = 0; sysMemDeltaMB = 0 }
    if ($sCpu -and $nCpu) { $d.cpuDelta = $sCpu.avgCpu - $nCpu.avgCpu; $d.sensorCpu = $sCpu.avgCpu; $d.noSensorCpu = $nCpu.avgCpu }
    if ($sMem -and $nMem) { $d.memDeltaMB = $sMem.avgMemMB - $nMem.avgMemMB } elseif ($sMem) { $d.memDeltaMB = $sMem.avgMemMB }
    if ($sDisk -and $nDisk) { $d.diskReadDeltaBps = $sDisk.readBps - $nDisk.readBps; $d.diskWriteDeltaBps = $sDisk.writeBps - $nDisk.writeBps }
    if ($sSysCpu -and $nSysCpu) { $d.sysCpuDelta = $sSysCpu.avgCpu - $nSysCpu.avgCpu }
    if ($sSysMem -and $nSysMem) { $d.sysMemDeltaMB = $nSysMem.avgAvailableMB - $sSysMem.avgAvailableMB }
    if ($sCpu -and $nCpu) { $findings.sensorDeltas += $d }
    elseif ($sCpu) { $d.sensorCpu = $sCpu.avgCpu; $d.noSensorCpu = 0; $d.cpuDelta = $sCpu.avgCpu; $findings.sensorDeltas += $d }
}

$diskQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_disk`") |> filter(fn: (r) => r._field =~ /Disk.*Read.*Bytes|Disk.*Write.*Bytes/) |> group(columns: [`"host`", `"scenario`", `"_field`"]) |> mean() |> group() |> yield(name: `"disk`")"
$diskMap = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $diskQ))) {
    $k = "$($r.host)|$($r.scenario)"
    if (-not $diskMap[$k]) { $diskMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; readBps = 0; writeBps = 0 } }
    $v = [double]($r._value)
    if ($r._field -like "*Read*") { $diskMap[$k].readBps = $v }
    if ($r._field -like "*Write*") { $diskMap[$k].writeBps = $v }
}
$findings.diskIo = @($diskMap.Values)

$json = $findings | ConvertTo-Json -Depth 5
if ($OutputPath) { $json | Set-Content -Path $OutputPath -Encoding UTF8; Write-Host "InfluxDB findings written to $OutputPath" } else { $json }
