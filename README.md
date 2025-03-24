# R720 System Cooling

A Bash script designed to dynamically control fan speeds on a Dell PowerEdge R720 running Linux. Optimizes cooling before, during, and after CPU load for quiet idle operation and aggressive heat dissipation under stress.

---

## Features
- **Dynamic Fan Control:** Adjusts fan speeds based on CPU temperature and usage.
- **Pre-Cooling:** Boosts fans preemptively when CPU usage spikes, minimizing thermal peaks.
- **Quiet Idle:** Lowers fan speeds at idle (e.g., 40% at 35°C) for reduced noise.
- **Aggressive Load Cooling:** Scales to 100% (~12,000 RPM) under heavy load (e.g., 55°C or 75% usage).
- **System Monitoring:** Logs CPU, memory, and power usage alongside temperature data.

---

## Requirements
- **`ipmitool`:** For BMC fan control and sensor readings. Install with `sudo pacman -S ipmitool`.
- **`sysstat`:** For CPU usage monitoring via `mpstat`. Install with `sudo pacman -S sysstat`.

---

## Tested On
### CPU Info
| Property             | Value                                    |
|----------------------|------------------------------------------|
| Model Name           | Intel(R) Xeon(R) CPU E5-2670 v2 @ 2.50GHz |
| CPU(s)               | 40 (20 cores, 40 threads with HT)        |
| Scaling MHz          | Varies (e.g., 66% of max under load)     |
| Max MHz              | 3300.0000 (Turbo Boost)                  |
| Min MHz              | 1200.0000 (Idle)                         |
| NUMA Node0 CPU(s)    | 0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38 |
| NUMA Node1 CPU(s)    | 1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39 |

### Memory Info
| Property | Total  | Used  | Free  | Shared | Buff/Cache | Available |
|----------|--------|-------|-------|--------|------------|-----------|
| Mem      | 755Gi  | 7.0Gi | 751Gi | 85Mi   | 1.1Gi      | 748Gi     |

### System Info
- **OS:** Linux void-server 6.13.7-arch1-1 #1 SMP PREEMPT_DYNAMIC Thu, 13 Mar 2025 18:12:00 +0000 x86_64 GNU/Linux

### Power Usage
- **Pwr Consumption:** 224.000 Watts (Idle) | OK | Max: 1792W Critical: 1974W

---

## Installation
1. Clone the repository:
   ```bash
   git clone https://github.com/ORDL-AMF/R720-System-Cooling.git
   cd R720-System-Cooling
