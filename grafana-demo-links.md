# Grafana Demo Links — Top 5 Peak Scenarios (from Presentation)

**Dashboard UID:** `activeprobe-perf-001`  
**Base URL:** http://172.46.16.24:3000/d/activeprobe-perf-001

All links use Host: TEST-PERF-3 + TEST-PERF-4 (sensor vs no-sensor comparison). Time ranges are centered on the exact peak timestamp from InfluxDB.

---

## 1. combined_high_density — 14% Peak (worst case)

**Peak:** 2026-02-19 06:28 UTC | Raw: 112% → 14% normalized

```
http://172.46.16.24:3000/d/activeprobe-perf-001?var-host=TEST-PERF-3&var-host=TEST-PERF-4&var-scenario=combined_high_density&from=2026-02-19T06:15:00.000Z&to=2026-02-19T06:45:00.000Z
```

---

## 2. user_account_modify — 9.9% Peak

**Peak:** 2026-02-19 18:43 UTC | Raw: 79% → 9.9% normalized  
**Also shows:** System CPU 21.2% vs 2.0% → +19.1% sensor overhead

```
http://172.46.16.24:3000/d/activeprobe-perf-001?var-host=TEST-PERF-3&var-host=TEST-PERF-4&var-scenario=user_account_modify&from=2026-02-19T18:40:00.000Z&to=2026-02-19T18:52:00.000Z
```

---

## 3. soak_test — 9.4% Peak

**Peak:** 2026-02-21 13:59 UTC | Raw: 75% → 9.4% normalized

```
http://172.46.16.24:3000/d/activeprobe-perf-001?var-host=TEST-PERF-3&var-host=TEST-PERF-4&var-scenario=soak_test&from=2026-02-21T13:50:00.000Z&to=2026-02-21T14:15:00.000Z
```

---

## 4. registry_storm — 8.6% Peak

**Peak:** 2026-02-19 13:51 UTC | Raw: 69% → 8.6% normalized

```
http://172.46.16.24:3000/d/activeprobe-perf-001?var-host=TEST-PERF-3&var-host=TEST-PERF-4&var-scenario=registry_storm&from=2026-02-19T13:40:00.000Z&to=2026-02-19T14:05:00.000Z
```

---

## 5. process_storm — 5.8% Peak

**Peak:** 2026-02-22 22:07 UTC | Raw: 46% → 5.8% normalized

```
http://172.46.16.24:3000/d/activeprobe-perf-001?var-host=TEST-PERF-3&var-host=TEST-PERF-4&var-scenario=process_storm&from=2026-02-22T21:55:00.000Z&to=2026-02-22T22:25:00.000Z
```

---

---

## Memory-focused link (lowest free memory / highest sensor memory)

**Scenario:** combined_high_density (different run than CPU peak)  
**When:** 2026-02-19 ~01:00 UTC — lowest available memory (5 GB) and highest sensor Working Set

```
http://172.46.16.24:3000/d/activeprobe-perf-001?var-host=TEST-PERF-3&var-host=TEST-PERF-4&var-scenario=combined_high_density&from=2026-02-19T00:55:00.000Z&to=2026-02-19T01:25:00.000Z
```

Use this to show the "Total System peak metrics" style view: low free memory (6 GB) vs no-sensor (14 GB), and sensor memory consumption.

---

## Summary Table

| Scenario              | Peak (normalized) | Peak (raw) | Date       |
|-----------------------|-------------------|------------|------------|
| combined_high_density | 14%               | 112%       | 2026-02-19 |
| user_account_modify   | 9.9%              | 79%        | 2026-02-19 |
| soak_test             | 9.4%              | 75%        | 2026-02-21 |
| registry_storm        | 8.6%              | 69%        | 2026-02-19 |
| process_storm         | 5.8%              | 46%        | 2026-02-22 |
