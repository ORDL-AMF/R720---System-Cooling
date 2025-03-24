# R720---System-Cooling
A sh script to control fan speeds before, during, after load on a Dell Poweredge R720, linux operating system.

# Requirements
ipmitool
sysstat

# Tested on
CPU Info:
CPU(s):                               40
On-line CPU(s) list:                  0-39
Model name:                           Intel(R) Xeon(R) CPU E5-2690 v2 @ 3.00GHz
CPU(s) scaling MHz:                   66%
CPU max MHz:                          3600.0000
CPU min MHz:                          1200.0000
NUMA node0 CPU(s):                    0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38
NUMA node1 CPU(s):                    1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39
Memory Info:
Mem:           755Gi       7.0Gi       751Gi        85Mi       1.1Gi       748Gi
System Info:
Linux void-server 6.13.7-arch1-1 #1 SMP PREEMPT_DYNAMIC Thu, 13 Mar 2025 18:12:00 +0000 x86_64 GNU/Linux
Power Usage:
Pwr Consumption  | 224.000    | Watts      | ok    | na        | na        | na        | 1792.000  | 1974.000  | na    
