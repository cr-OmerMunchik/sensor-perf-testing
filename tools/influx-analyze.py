#!/usr/bin/env python3
"""
Queries InfluxDB for sensor performance metrics and outputs findings as JSON.
Run on MON VM: python influx-analyze.py --url http://localhost:8086 --token YOUR_TOKEN
"""
import argparse
import json
import sys
import urllib.request
from collections import OrderedDict
from datetime import datetime

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://localhost:8086")
    p.add_argument("--token", required=True)
    p.add_argument("--range", default="-7d")
    p.add_argument("--output", "-o", help="Output JSON file path")
    args = p.parse_args()

    query_url = f"{args.url.rstrip('/')}/api/v2/query?org=activeprobe-perf"
    headers = {
        "Authorization": f"Token {args.token}",
        "Accept": "application/csv",
        "Content-Type": "application/vnd.flux",
    }

    def query(flux: str):
        req = urllib.request.Request(query_url, data=flux.encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read().decode()
        except Exception as e:
            print(f"Warning: Query failed: {e}", file=sys.stderr)
            return []
        rows = []
        header = None
        for line in raw.splitlines():
            if line.startswith("#"):
                continue
            parts = line.split(",")
            if len(parts) < 2:
                continue
            r0, r1 = parts[0], parts[1]
            if len(parts) >= 3 and parts[0] == "" and parts[1] == "result" and parts[2] == "table":
                header = parts
                continue
            if parts[0] == "result" and parts[1] == "table":
                header = parts
                continue
            if header is None or len(parts) < len(header):
                continue
            obj = {}
            for i, key in enumerate(header):
                if i < len(parts) and key:
                    obj[key] = parts[i]
            if obj:
                rows.append(obj)
        return rows

    tr = args.range

    # 1. Sensor CPU by scenario and host
    cpu_q = f'''from(bucket: "telegraf")
  |> range(start: {tr})
  |> filter(fn: (r) => r._measurement == "sensor_process")
  |> filter(fn: (r) => r._field == "Percent_Processor_Time")
  |> group(columns: ["host", "scenario"])
  |> mean()
  |> group()
  |> yield(name: "avg")'''
    peak_q = f'''from(bucket: "telegraf")
  |> range(start: {tr})
  |> filter(fn: (r) => r._measurement == "sensor_process")
  |> filter(fn: (r) => r._field == "Percent_Processor_Time")
  |> group(columns: ["host", "scenario"])
  |> max()
  |> group()
  |> yield(name: "peak")'''

    avg_cpu = query(cpu_q)
    peak_cpu = query(peak_q)
    cpu_by_key = {}
    for r in avg_cpu:
        h, s = r.get("host", ""), r.get("scenario", "")
        v = r.get("_value", r.get("value", 0))
        k = f"{h}|{s}"
        cpu_by_key[k] = {"host": h, "scenario": s, "avgCpu": float(v) if v else 0, "peakCpu": 0}
    for r in peak_cpu:
        h, s = r.get("host", ""), r.get("scenario", "")
        v = r.get("_value", r.get("value", 0))
        k = f"{h}|{s}"
        if k in cpu_by_key:
            cpu_by_key[k]["peakCpu"] = float(v) if v else 0
    sensor_cpu = list(cpu_by_key.values())

    # 2. Sensor memory
    mem_q = f'''from(bucket: "telegraf")
  |> range(start: {tr})
  |> filter(fn: (r) => r._measurement == "sensor_process")
  |> filter(fn: (r) => r._field == "Working_Set")
  |> group(columns: ["host", "scenario"])
  |> sum()
  |> map(fn: (r) => ({{ r with _value: r._value / 1048576.0 }}))
  |> group()
  |> yield(name: "mem_mb")'''
    mem_data = query(mem_q)
    sensor_memory = []
    for r in mem_data:
        v = r.get("_value", r.get("value", 0))
        sensor_memory.append({
            "host": r.get("host", ""),
            "scenario": r.get("scenario", ""),
            "avgMemMB": float(v) if v else 0,
        })

    # 3. KPI failures
    kpi_failures = []
    for c in sensor_cpu:
        if c.get("peakCpu", 0) > 15:
            kpi_failures.append({"type": "cpu", "host": c["host"], "scenario": c["scenario"], "value": c["peakCpu"], "threshold": 15})
    for m in sensor_memory:
        if m.get("avgMemMB", 0) > 500:
            kpi_failures.append({"type": "memory", "host": m["host"], "scenario": m["scenario"], "value": m["avgMemMB"], "threshold": 500})

    # 4. Sensor vs no-sensor deltas (TEST-PERF-3 vs TEST-PERF-4)
    sensor_host, no_sensor_host = "TEST-PERF-3", "TEST-PERF-4"
    scenarios = set(c.get("scenario") for c in sensor_cpu if c.get("scenario"))
    sensor_deltas = []
    for sc in scenarios:
        s_row = next((c for c in sensor_cpu if c.get("host") == sensor_host and c.get("scenario") == sc), None)
        n_row = next((c for c in sensor_cpu if c.get("host") == no_sensor_host and c.get("scenario") == sc), None)
        if s_row and n_row:
            sensor_deltas.append({
                "scenario": sc,
                "cpuDelta": s_row.get("avgCpu", 0) - n_row.get("avgCpu", 0),
                "sensorCpu": s_row.get("avgCpu", 0),
                "noSensorCpu": n_row.get("avgCpu", 0),
            })

    # 5. System CPU
    sys_cpu_q = f'''from(bucket: "telegraf")
  |> range(start: {tr})
  |> filter(fn: (r) => r._measurement == "win_cpu")
  |> filter(fn: (r) => r._field == "Percent_Processor_Time")
  |> filter(fn: (r) => r.instance == "_Total")
  |> group(columns: ["host", "scenario"])
  |> mean()
  |> group()
  |> yield(name: "sys_cpu")'''
    sys_cpu = [{"host": r.get("host",""), "scenario": r.get("scenario",""), "avgCpu": float(r.get("_value", r.get("value", 0)) or 0)} for r in query(sys_cpu_q)]

    # 6. System memory
    sys_mem_q = f'''from(bucket: "telegraf")
  |> range(start: {tr})
  |> filter(fn: (r) => r._measurement == "win_mem")
  |> filter(fn: (r) => r._field == "Available_MBytes")
  |> group(columns: ["host", "scenario"])
  |> mean()
  |> group()
  |> yield(name: "avail_mb")'''
    system_mem = [{"host": r.get("host",""), "scenario": r.get("scenario",""), "availableMB": float(r.get("_value", r.get("value", 0)) or 0)} for r in query(sys_mem_q)]

    # 7. Disk I/O
    disk_q = f'''from(bucket: "telegraf")
  |> range(start: {tr})
  |> filter(fn: (r) => r._measurement == "win_disk")
  |> filter(fn: (r) => r._field =~ /Disk.*Read.*Bytes|Disk.*Write.*Bytes/)
  |> group(columns: ["host", "scenario", "_field"])
  |> mean()
  |> group()
  |> yield(name: "disk")'''
    disk_data = query(disk_q)
    disk_by_key = {}
    for r in disk_data:
        k = f"{r.get('host','')}|{r.get('scenario','')}"
        if k not in disk_by_key:
            disk_by_key[k] = {"host": r.get("host",""), "scenario": r.get("scenario",""), "readBps": 0, "writeBps": 0}
        v = float(r.get("_value", r.get("value", 0)) or 0)
        f = r.get("_field", "")
        if "Read" in f:
            disk_by_key[k]["readBps"] = v
        if "Write" in f:
            disk_by_key[k]["writeBps"] = v
    disk_io = list(disk_by_key.values())

    findings = OrderedDict(
        timestamp=datetime.now().isoformat(),
        timeRange=tr,
        sensorCpu=sensor_cpu,
        sensorMemory=sensor_memory,
        systemCpu=sys_cpu,
        systemMem=system_mem,
        diskIo=disk_io,
        kpiFailures=kpi_failures,
        sensorDeltas=sensor_deltas,
    )
    out = json.dumps(findings, indent=2)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(out)
        print(f"InfluxDB findings written to {args.output}", file=sys.stderr)
    else:
        print(out)

if __name__ == "__main__":
    main()
