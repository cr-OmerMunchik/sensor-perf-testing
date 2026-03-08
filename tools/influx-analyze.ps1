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
    [switch]$DebugDumpCsv,
    [string]$HostFilter = ""
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
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $out = @(); $h = $null
    foreach ($line in ($txt -split "`n")) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
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
                $v = [string]$obj._value
                $d = 0.0
                $parsed = [double]::TryParse($v, [System.Globalization.NumberStyles]::Any, $inv, [ref]$d)
                if (-not $parsed -or $d -eq 0) {
                    for ($j = $p.Count - 1; $j -ge 0; $j--) {
                        $tryVal = $p[$j]
                        if ([double]::TryParse($tryVal, [System.Globalization.NumberStyles]::Any, $inv, [ref]$d) -and $d -gt 0) {
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

$findings = [ordered]@{ timestamp = (Get-Date -Format "o"); timeRange = $tr; testStartTime = ""; testEndTime = ""; kernelPoolMB = @(); sensorCpu = @(); sensorMemory = @(); systemCpu = @(); systemMem = @(); diskIo = @(); kpiFailures = @(); sensorDeltas = @(); networkIo = @(); sensorDbSize = @(); sensorLiveness = @(); sensorLivenessUptime = @(); driverInstances = @(); systemProcessCpu = @(); systemProcessMemory = @(); versionComparison = @(); backendComparison = @() }

# Test time range: find earliest and latest data points
$timeMinQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> group() |> first() |> keep(columns: [`"_time`"]) |> yield(name: `"tmin`")"
$timeMaxQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_cpu`") |> group() |> last() |> keep(columns: [`"_time`"]) |> yield(name: `"tmax`")"
$tMinRows = Parse-Csv (Invoke-InfluxQuery $timeMinQ)
$tMaxRows = Parse-Csv (Invoke-InfluxQuery $timeMaxQ)
if ($tMinRows.Count -gt 0) { $findings.testStartTime = $tMinRows[0]._time }
if ($tMaxRows.Count -gt 0) { $findings.testEndTime = $tMaxRows[0]._time }

# Sensor CPU: sum across processes at each timestamp, normalize by num_cores, then avg/max over time
$cpuQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> map(fn: (r) => ({ r with _value: r._value / float(v: r.num_cores) })) |> group(columns: [`"_time`", `"host`", `"scenario`"]) |> sum() |> group(columns: [`"host`", `"scenario`"]) |> mean() |> group() |> yield(name: `"avg`")"
$peakQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> map(fn: (r) => ({ r with _value: r._value / float(v: r.num_cores) })) |> group(columns: [`"_time`", `"host`", `"scenario`"]) |> sum() |> group(columns: [`"host`", `"scenario`"]) |> max() |> group() |> yield(name: `"peak`")"
$avgCpu = Parse-Csv (Invoke-InfluxQuery $cpuQ)
$peakCpu = Parse-Csv (Invoke-InfluxQuery $peakQ)
$cpuMap = @{}
foreach ($r in $avgCpu) { $k = "$($r.host)|$($r.scenario)"; $cpuMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; avgCpu = [double]($r._value); peakCpu = 0 } }
foreach ($r in $peakCpu) { $k = "$($r.host)|$($r.scenario)"; if ($cpuMap[$k]) { $cpuMap[$k].peakCpu = [double]($r._value) } }
$findings.sensorCpu = @($cpuMap.Values)

$memAvgQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Working_Set`") |> group(columns: [`"_time`", `"host`", `"scenario`"]) |> sum() |> group(columns: [`"host`", `"scenario`"]) |> mean() |> map(fn: (r) => ({ r with _value: r._value / 1048576.0 })) |> group() |> yield(name: `"mem`")"
$memPeakQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Working_Set`") |> group(columns: [`"_time`", `"host`", `"scenario`"]) |> sum() |> group(columns: [`"host`", `"scenario`"]) |> max() |> map(fn: (r) => ({ r with _value: r._value / 1048576.0 })) |> group() |> yield(name: `"mempeak`")"
$memMap = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $memAvgQ))) { $k = "$($r.host)|$($r.scenario)"; $memMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; avgMemMB = [double]($r._value); peakMemMB = 0 } }
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $memPeakQ))) { $k = "$($r.host)|$($r.scenario)"; if ($memMap[$k]) { $memMap[$k].peakMemMB = [double]($r._value) } }
$findings.sensorMemory = @($memMap.Values)

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
$sysMemPeakQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_mem`") |> filter(fn: (r) => r._field == `"Available_MBytes`") |> group(columns: [`"host`", `"scenario`"]) |> min() |> group() |> yield(name: `"avail`")"
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

### Kernel Pool Memory (Pool Paged + Pool Nonpaged from win_mem)
$kernelPoolQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_mem`") |> filter(fn: (r) => r._field == `"Pool_Paged_Bytes`" or r._field == `"Pool_Nonpaged_Bytes`") |> group(columns: [`"host`", `"scenario`", `"_field`"]) |> mean() |> group() |> yield(name: `"kpool`")"
$kernelPoolPeakQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_mem`") |> filter(fn: (r) => r._field == `"Pool_Paged_Bytes`" or r._field == `"Pool_Nonpaged_Bytes`") |> group(columns: [`"host`", `"scenario`", `"_field`"]) |> max() |> group() |> yield(name: `"kpoolpeak`")"
$kpMap = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $kernelPoolQ))) {
    $k = "$($r.host)|$($r.scenario)"
    if (-not $kpMap[$k]) { $kpMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; avgPagedMB = 0; avgNonpagedMB = 0; peakPagedMB = 0; peakNonpagedMB = 0 } }
    $v = [double]($r._value) / 1048576
    if ($r._field -like "*Paged*" -and $r._field -notlike "*Nonpaged*") { $kpMap[$k].avgPagedMB = $v }
    if ($r._field -like "*Nonpaged*") { $kpMap[$k].avgNonpagedMB = $v }
}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $kernelPoolPeakQ))) {
    $k = "$($r.host)|$($r.scenario)"
    if ($kpMap[$k]) {
        $v = [double]($r._value) / 1048576
        if ($r._field -like "*Paged*" -and $r._field -notlike "*Nonpaged*") { $kpMap[$k].peakPagedMB = $v }
        if ($r._field -like "*Nonpaged*") { $kpMap[$k].peakNonpagedMB = $v }
    }
}
$findings.kernelPoolMB = @($kpMap.Values)

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

### Network I/O
$netQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"win_net`") |> filter(fn: (r) => r._field == `"Bytes_Received_persec`" or r._field == `"Bytes_Sent_persec`") |> group(columns: [`"host`", `"scenario`", `"_field`"]) |> mean() |> group() |> yield(name: `"net`")"
$netMap = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $netQ))) {
    $k = "$($r.host)|$($r.scenario)"
    if (-not $netMap[$k]) { $netMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; receivedBps = 0; sentBps = 0 } }
    $v = [double]($r._value)
    if ($r._field -like "*Received*") { $netMap[$k].receivedBps = $v }
    if ($r._field -like "*Sent*") { $netMap[$k].sentBps = $v }
}
$findings.networkIo = @($netMap.Values)

### Sensor DB Size
$dbQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_db_size`") |> group(columns: [`"host`", `"scenario`"]) |> last() |> group() |> yield(name: `"db`")"
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $dbQ))) {
    $findings.sensorDbSize += [ordered]@{ host = $r.host; scenario = $r.scenario; sizeBytes = [long]($r._value) }
}

### Sensor Liveness
$liveQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_liveness`") |> group(columns: [`"host`", `"_field`"]) |> last() |> group() |> yield(name: `"live`")"
$liveMap = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $liveQ))) {
    $k = $r.host
    if (-not $liveMap[$k]) { $liveMap[$k] = [ordered]@{ host = $r.host; minionhost = 0; activeconsole = 0 } }
    if ($r._field -eq "minionhost") { $liveMap[$k].minionhost = [int]($r._value) }
    if ($r._field -eq "activeconsole") { $liveMap[$k].activeconsole = [int]($r._value) }
}
$findings.sensorLiveness = @($liveMap.Values)

# Liveness uptime percentage (count of up samples / total samples)
$totalQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_liveness`") |> group(columns: [`"host`", `"_field`"]) |> count() |> group() |> yield(name: `"total`")"
$upQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_liveness`") |> map(fn: (r) => ({ r with _value: if r._value == 1 then 1 else 0 })) |> group(columns: [`"host`", `"_field`"]) |> sum() |> group() |> yield(name: `"up`")"
$totalCounts = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $totalQ))) {
    $k = "$($r.host)|$($r._field)"
    $totalCounts[$k] = [int]($r._value)
}
$upCounts = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $upQ))) {
    $k = "$($r.host)|$($r._field)"
    $upCounts[$k] = [int]($r._value)
}
$uptimeMap = @{}
foreach ($k in $totalCounts.Keys) {
    $parts = $k -split '\|'
    $hostName = $parts[0]; $field = $parts[1]
    if (-not $uptimeMap[$hostName]) { $uptimeMap[$hostName] = [ordered]@{ host = $hostName; minionhost_uptime = 0; activeconsole_uptime = 0 } }
    $total = $totalCounts[$k]
    $up = if ($upCounts[$k]) { $upCounts[$k] } else { 0 }
    $pct = if ($total -gt 0) { [math]::Round(($up / $total) * 100, 1) } else { 0 }
    if ($field -eq "minionhost") { $uptimeMap[$hostName].minionhost_uptime = $pct }
    if ($field -eq "activeconsole") { $uptimeMap[$hostName].activeconsole_uptime = $pct }
}
$findings.sensorLivenessUptime = @($uptimeMap.Values)

### Driver Instances
$drvQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_driver_instances`") |> group(columns: [`"host`"]) |> last() |> group() |> yield(name: `"drv`")"
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $drvQ))) {
    $findings.driverInstances += [ordered]@{ host = $r.host; count = [int]($r._value) }
}

### System + Sensor Process CPU (per-process, per-scenario, avg and peak, normalized by num_cores)
$sysProcAvgQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"system_process`" or r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> map(fn: (r) => ({ r with _value: r._value / float(v: r.num_cores) })) |> group(columns: [`"host`", `"scenario`", `"instance`"]) |> mean() |> group() |> yield(name: `"sysproc`")"
$sysProcPeakQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"system_process`" or r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> map(fn: (r) => ({ r with _value: r._value / float(v: r.num_cores) })) |> group(columns: [`"host`", `"scenario`", `"instance`"]) |> max() |> group() |> yield(name: `"sysprocpeak`")"
$spMap = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $sysProcAvgQ))) {
    $k = "$($r.host)|$($r.scenario)|$($r.instance)"; $spMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; process = $r.instance; avgCpu = [double]($r._value); peakCpu = 0 }
}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $sysProcPeakQ))) {
    $k = "$($r.host)|$($r.scenario)|$($r.instance)"; if ($spMap[$k]) { $spMap[$k].peakCpu = [double]($r._value) }
}
$findings.systemProcessCpu = @($spMap.Values)

### System + Sensor Process Memory (per-process, per-scenario, avg and peak Working Set in MB)
$sysProcMemAvgQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"system_process`" or r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Working_Set`") |> group(columns: [`"host`", `"scenario`", `"instance`"]) |> mean() |> map(fn: (r) => ({ r with _value: r._value / 1048576.0 })) |> group() |> yield(name: `"sysprocmem`")"
$sysProcMemPeakQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"system_process`" or r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Working_Set`") |> group(columns: [`"host`", `"scenario`", `"instance`"]) |> max() |> map(fn: (r) => ({ r with _value: r._value / 1048576.0 })) |> group() |> yield(name: `"sysprocmempeak`")"
$spmMap = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $sysProcMemAvgQ))) {
    $k = "$($r.host)|$($r.scenario)|$($r.instance)"; $spmMap[$k] = [ordered]@{ host = $r.host; scenario = $r.scenario; process = $r.instance; avgMemMB = [double]($r._value); peakMemMB = 0 }
}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $sysProcMemPeakQ))) {
    $k = "$($r.host)|$($r.scenario)|$($r.instance)"; if ($spmMap[$k]) { $spmMap[$k].peakMemMB = [double]($r._value) }
}
$findings.systemProcessMemory = @($spmMap.Values)

### Version Comparison (v26.1 vs v24.1, normalized by num_cores)
$verCpuQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> map(fn: (r) => ({ r with _value: r._value / float(v: r.num_cores) })) |> group(columns: [`"_time`", `"host`", `"scenario`", `"sensor_version`"]) |> sum() |> group(columns: [`"host`", `"scenario`", `"sensor_version`"]) |> mean() |> group() |> yield(name: `"ver`")"
$verMap = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $verCpuQ))) {
    $k = "$($r.scenario)|$($r.sensor_version)"
    if (-not $verMap[$k]) { $verMap[$k] = [ordered]@{ scenario = $r.scenario; sensorVersion = $r.sensor_version; avgCpu = [double]($r._value); hosts = @() } }
    $verMap[$k].hosts += $r.host
}
$findings.versionComparison = @($verMap.Values)

### Backend Comparison (Phoenix vs Legacy, normalized by num_cores)
$backCpuQ = "from(bucket: `"telegraf`") |> range(start: $tr) |> filter(fn: (r) => r._measurement == `"sensor_process`") |> filter(fn: (r) => r._field == `"Percent_Processor_Time`") |> map(fn: (r) => ({ r with _value: r._value / float(v: r.num_cores) })) |> group(columns: [`"_time`", `"host`", `"scenario`", `"backend_type`"]) |> sum() |> group(columns: [`"host`", `"scenario`", `"backend_type`"]) |> mean() |> group() |> yield(name: `"back`")"
$backMap = @{}
foreach ($r in (Parse-Csv (Invoke-InfluxQuery $backCpuQ))) {
    $k = "$($r.scenario)|$($r.backend_type)"
    if (-not $backMap[$k]) { $backMap[$k] = [ordered]@{ scenario = $r.scenario; backendType = $r.backend_type; avgCpu = [double]($r._value); hosts = @() } }
    $backMap[$k].hosts += $r.host
}
$findings.backendComparison = @($backMap.Values)

$json = $findings | ConvertTo-Json -Depth 5
if ($OutputPath) { $json | Set-Content -Path $OutputPath -Encoding UTF8; Write-Host "InfluxDB findings written to $OutputPath" } else { $json }
