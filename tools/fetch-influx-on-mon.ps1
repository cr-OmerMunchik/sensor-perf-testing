<#
.SYNOPSIS
    Run on MON VM to fetch InfluxDB data. Then SCP the JSON back to your workstation.
.EXAMPLE
    # On MON VM (ssh admin@172.46.16.24):
    cd C:\temp
    $env:INFLUXDB_TOKEN = "your-token"
    powershell -ExecutionPolicy Bypass -File influx-analyze.ps1 -InfluxUrl http://localhost:8086 -OutputPath C:\temp\influx-data.json -DebugDumpCsv
    
    # On workstation:
    scp admin@172.46.16.24:C:\temp\influx-data.json .
    scp admin@172.46.16.24:C:\temp\influx-raw-win_cpu.csv .
    scp admin@172.46.16.24:C:\temp\influx-raw-win_mem.csv .
#>
