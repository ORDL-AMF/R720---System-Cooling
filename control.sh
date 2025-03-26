#!/bin/bash
# -----------------------------------------------------------------------------
# Title: R720 Fan Control Script
# Author: Winsock
# Company: Open Research and Development Laboratories (ORDL)
# Location: Pennsylvania, USA
# Contact: aferguson@ordl.org
# Version: 1.7
# Date: March 25, 2025
# Description: Custom fan control for Dell PowerEdge R720 with dual Xeon E5-2690 v2.
#              Quiet idle, aggressive cooling under load, with CPU usage-based pre-cooling.
#              Detailed fan speed logging, manual fan control set at startup.
# Requirements: ipmitool, sysstat (for mpstat), bc
# -----------------------------------------------------------------------------

# Script constants
SCRIPT_NAME="R720 Fan Control Script"
SCRIPT_VERSION="1.7"

echo "Starting $SCRIPT_NAME..."
echo "Initial sensor readings:"
sudo /usr/bin/ipmitool -I open sensor | grep -E "Fan|Temp|Watts"

# Dependency checks
for cmd in ipmitool mpstat bc; do
  if ! command -v "$cmd" >/dev/null; then
    echo "Error: $cmd not found. Install with 'pacman -S ${cmd/ipmitool/ipmitool sysstat}'."
    exit 1
  fi
done

# Log system info at startup
LOG_FILE="/var/log/r720-fancontrol.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "$TIMESTAMP - $SCRIPT_NAME v$SCRIPT_VERSION Startup:" | tee -a "$LOG_FILE"
echo "CPU: $(lscpu | grep "Model name" | awk -F': ' '{print $2}'), Threads: $(lscpu | grep "CPU(s):" | head -n1 | awk '{print $2}')" | tee -a "$LOG_FILE"
echo "Memory Total: $(free -h | grep "Mem:" | awk '{print $2}')" | tee -a "$LOG_FILE"
echo "OS: $(uname -a)" | tee -a "$LOG_FILE"

# Set manual fan control at startup
sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x01 0x00
if [ $? -eq 0 ]; then
  echo "$TIMESTAMP - Manual fan control enabled" | tee -a "$LOG_FILE"
else
  echo "$TIMESTAMP - Error: Failed to enable manual fan control" | tee -a "$LOG_FILE"
  exit 1
fi

# Variables
LAST_SPEED="25"
LAST_USAGE1=0
LAST_USAGE2=0
LAST_TEMP_TRIGGER=0
COUNTER=0

while true; do
  # Get temps
  INLET_TEMP=$(sudo /usr/bin/ipmitool -I open sensor | grep "Inlet Temp" | awk -F'|' '{print $2}' | tr -d ' ' | cut -d'.' -f1)
  EXHAUST_TEMP=$(sudo /usr/bin/ipmitool -I open sensor | grep "Exhaust Temp" | awk -F'|' '{print $2}' | tr -d ' ' | cut -d'.' -f1)
  CPU_TEMPS=$(sudo /usr/bin/ipmitool -I open sensor | grep "^Temp" | awk -F'|' '{print $2}' | tr -d ' ' | cut -d'.' -f1)
  CPU1_TEMP=$(echo "$CPU_TEMPS" | head -n1)
  CPU2_TEMP=$(echo "$CPU_TEMPS" | tail -n1)

  # Validate temps
  if ! [[ "$INLET_TEMP" =~ ^[0-9]+$ ]] || ! [[ "$EXHAUST_TEMP" =~ ^[0-9]+$ ]] || \
     ! [[ "$CPU1_TEMP" =~ ^[0-9]+$ ]] || ! [[ "$CPU2_TEMP" =~ ^[0-9]+$ ]]; then
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$TIMESTAMP - Error: Invalid temp values—Inlet: '$INLET_TEMP', Exhaust: '$EXHAUST_TEMP', CPU1: '$CPU1_TEMP', CPU2: '$CPU2_TEMP'" | tee -a "$LOG_FILE"
    sleep 30
    continue
  fi

  MAX_TEMP=$INLET_TEMP
  [ "$EXHAUST_TEMP" -gt "$MAX_TEMP" ] && MAX_TEMP=$EXHAUST_TEMP
  [ "$CPU1_TEMP" -gt "$MAX_TEMP" ] && MAX_TEMP=$CPU1_TEMP
  [ "$CPU2_TEMP" -gt "$MAX_TEMP" ] && MAX_TEMP=$CPU2_TEMP

  # Get CPU usage
  CPU_USAGE=$(mpstat -P ALL 1 1 | tail -n 2 | awk '{print 100 - $NF}')
  CPU1_USAGE=$(echo "$CPU_USAGE" | head -n1)
  CPU2_USAGE=$(echo "$CPU_USAGE" | tail -n1)

  # Pre-cool if usage spikes
  USAGE_SPIKE=0
  SPIKE_REASON=""
  [ $(echo "$CPU1_USAGE - $LAST_USAGE1 > 30" | bc) -eq 1 ] && USAGE_SPIKE=1 && SPIKE_REASON="CPU1 usage spike: $LAST_USAGE1% to $CPU1_USAGE%"
  [ $(echo "$CPU2_USAGE - $LAST_USAGE2 > 30" | bc) -eq 1 ] && USAGE_SPIKE=1 && SPIKE_REASON="CPU2 usage spike: $LAST_USAGE2% to $CPU2_USAGE%"
  LAST_USAGE1=$CPU1_USAGE
  LAST_USAGE2=$CPU2_USAGE

  # Log and output
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$TIMESTAMP - Inlet: $INLET_TEMP°C, Exhaust: $EXHAUST_TEMP°C, CPU1: $CPU1_TEMP°C ($CPU1_USAGE%), CPU2: $CPU2_TEMP°C ($CPU2_USAGE%), Max: $MAX_TEMP°C" | tee -a "$LOG_FILE"
  sudo touch /tmp/cpu_temp 2>/dev/null && sudo chmod 644 /tmp/cpu_temp && sudo chown root:root /tmp/cpu_temp
  echo "$MAX_TEMP" > /tmp/cpu_temp && sync || echo "$TIMESTAMP - Error: Failed to write to /tmp/cpu_temp" | tee -a "$LOG_FILE"

  # Periodic system info (every 10 loops ~5min)
  COUNTER=$((COUNTER + 1))
  if [ $((COUNTER % 10)) -eq 0 ]; then
    echo "$TIMESTAMP - Memory Used: $(free -h | grep "Mem:" | awk '{print $3}') / $(free -h | grep "Mem:" | awk '{print $2}')" | tee -a "$LOG_FILE"
    CPU_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{print $1/1000}')
    echo "$TIMESTAMP - CPU Scaling: Current ${CPU_FREQ:-N/A} MHz" | tee -a "$LOG_FILE"
  fi

  # Fan control: Temp + Usage with detailed logging
  TEMP_DELTA=$(echo "$MAX_TEMP - $LAST_TEMP_TRIGGER" | bc)
  NEW_SPEED=""
  REASON=""
  if [ "$MAX_TEMP" -ge 55 ] || [ $(echo "$CPU1_USAGE > 75" | bc) -eq 1 ] || [ $(echo "$CPU2_USAGE > 75" | bc) -eq 1 ]; then
    NEW_SPEED="100"
    REASON="High load: Temp $MAX_TEMP°C >= 55°C or Usage CPU1 $CPU1_USAGE% / CPU2 $CPU2_USAGE% > 75%"
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x64
    [ $? -eq 0 ] && LAST_SPEED="100" && LAST_TEMP_TRIGGER=$MAX_TEMP || REASON="Failed to set 100%"
  elif [ "$MAX_TEMP" -ge 45 ] || [ $(echo "$CPU1_USAGE > 50" | bc) -eq 1 ] || [ $(echo "$CPU2_USAGE > 50" | bc) -eq 1 ]; then
    NEW_SPEED="80"
    REASON="Moderate load: Temp $MAX_TEMP°C >= 45°C or Usage CPU1 $CPU1_USAGE% / CPU2 $CPU2_USAGE% > 50%"
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x50
    [ $? -eq 0 ] && LAST_SPEED="80" && LAST_TEMP_TRIGGER=$MAX_TEMP || REASON="Failed to set 80%"
  elif { [ "$MAX_TEMP" -ge 40 ] || [ "$USAGE_SPIKE" -eq 1 ]; } && [ $(echo "$TEMP_DELTA >= 3 || $TEMP_DELTA <= -3" | bc) -eq 1 ]; then
    NEW_SPEED="60"
    REASON="${USAGE_SPIKE:+Pre-cool: $SPIKE_REASON}${USAGE_SPIKE:-Temp $MAX_TEMP°C >= 40°C, delta $TEMP_DELTA°C}"
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x3c
    [ $? -eq 0 ] && LAST_SPEED="60" && LAST_TEMP_TRIGGER=$MAX_TEMP || REASON="Failed to set 60%"
  elif [ "$MAX_TEMP" -ge 35 ] && [ "$LAST_SPEED" != "60" -o $(echo "$MAX_TEMP - 37 <= 0" | bc) -eq 1 ] && [ $(echo "$TEMP_DELTA >= 3 || $TEMP_DELTA <= -3" | bc) -eq 1 ]; then
    NEW_SPEED="40"
    REASON="Idle range: Temp $MAX_TEMP°C >= 35°C, delta $TEMP_DELTA°C"
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x28
    [ $? -eq 0 ] && LAST_SPEED="40" && LAST_TEMP_TRIGGER=$MAX_TEMP || REASON="Failed to set 40%"
  elif [ "$MAX_TEMP" -lt 33 ] || [ "$LAST_SPEED" != "40" -a "$MAX_TEMP" -lt 35 ]; then
    NEW_SPEED="25"
    REASON="Low temp: Temp $MAX_TEMP°C < 33°C"
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x19
    [ $? -eq 0 ] && LAST_SPEED="25" && LAST_TEMP_TRIGGER=$MAX_TEMP || REASON="Failed to set 25%"
  fi

  # Log fan speed change
  if [ -n "$NEW_SPEED" ] && [ "$NEW_SPEED" != "$LAST_SPEED" ]; then
    echo "$TIMESTAMP - Fan speed changed to $NEW_SPEED% (~$((NEW_SPEED * 120)) RPM) - Reason: $REASON" | tee -a "$LOG_FILE"
  elif [ -n "$REASON" ] && echo "$REASON" | grep -q "Failed"; then
    echo "$TIMESTAMP - Fan speed change failed - Reason: $REASON" | tee -a "$LOG_FILE"
  fi

  # High-temp alert
  if [ "$MAX_TEMP" -ge 80 ]; then
    echo "$TIMESTAMP - ALERT: High temperature detected ($MAX_TEMP°C)!" | tee -a "$LOG_FILE"
  fi

  sleep 5
  echo "Current fan speeds:"
  sudo /usr/bin/ipmitool -I open sensor | grep Fan | tee -a "$LOG_FILE"
  sleep 25
done
