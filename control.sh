#!/bin/bash
# -----------------------------------------------------------------------------
# Title: R720 Fan Control Script
# Author: Winsock
# Company: Open Research and Development Laboratories (ORDL)
# Location: Pennsylvania, USA
# Contact: aferguson@ordl.org
# Version: 1.0
# Date: March 24, 2025
# Description: Custom fan control for Dell PowerEdge R720 with dual Xeon E5-2670 v2.
#              Quiet idle, aggressive cooling under load, with CPU usage-based pre-cooling.
# Requirements: ipmitool, sysstat (for mpstat)
# -----------------------------------------------------------------------------

echo "Starting R720 fan control..."
echo "Initial sensor readings:"
sudo /usr/bin/ipmitool -I open sensor | grep -E "Fan|Temp|Watts"

# Install sysstat if missing
if ! command -v mpstat >/dev/null; then
  echo "Installing sysstat for CPU usage monitoring..."
  sudo pacman -S sysstat || { echo "Error: Failed to install sysstat"; exit 1; }
fi

# Ensure ipmitool is available
if ! command -v ipmitool >/dev/null; then
  echo "Error: ipmitool not found. Please install it (pacman -S ipmitool)."
  exit 1
fi

# Set manual fan control
sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x01 0x00
[ $? -eq 0 ] && echo "Automatic fan control disabled" || { echo "Warning: Failed to disable auto control"; exit 1; }

# Variables for hysteresis and usage tracking
LAST_SPEED="25"
LAST_USAGE1=0
LAST_USAGE2=0
LOG_FILE="/var/log/r720-fancontrol.log"

# Main loop
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
    echo "Error: Invalid temp values—Inlet: '$INLET_TEMP', Exhaust: '$EXHAUST_TEMP', CPU1: '$CPU1_TEMP', CPU2: '$CPU2_TEMP'"
    sleep 30
    continue
  fi

  MAX_TEMP=$INLET_TEMP
  [ "$EXHAUST_TEMP" -gt "$MAX_TEMP" ] && MAX_TEMP=$EXHAUST_TEMP
  [ "$CPU1_TEMP" -gt "$MAX_TEMP" ] && MAX_TEMP=$CPU1_TEMP
  [ "$CPU2_TEMP" -gt "$MAX_TEMP" ] && MAX_TEMP=$CPU2_TEMP

  # Get CPU usage (average over 1s)
  CPU_USAGE=$(mpstat -P ALL 1 1 | tail -n 2 | awk '{print 100 - $NF}')
  CPU1_USAGE=$(echo "$CPU_USAGE" | head -n1)
  CPU2_USAGE=$(echo "$CPU_USAGE" | tail -n1)

  # Pre-cool if usage spikes
  USAGE_SPIKE=0
  [ $(echo "$CPU1_USAGE - $LAST_USAGE1 > 30" | bc) -eq 1 ] && USAGE_SPIKE=1
  [ $(echo "$CPU2_USAGE - $LAST_USAGE2 > 30" | bc) -eq 1 ] && USAGE_SPIKE=1
  LAST_USAGE1=$CPU1_USAGE
  LAST_USAGE2=$CPU2_USAGE

  # Log and output
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$TIMESTAMP - Inlet: $INLET_TEMP°C, Exhaust: $EXHAUST_TEMP°C, CPU1: $CPU1_TEMP°C ($CPU1_USAGE%), CPU2: $CPU2_TEMP°C ($CPU2_USAGE%), Max: $MAX_TEMP°C"
  echo "$TIMESTAMP - Inlet: $INLET_TEMP°C, Exhaust: $EXHAUST_TEMP°C, CPU1: $CPU1_TEMP°C ($CPU1_USAGE%), CPU2: $CPU2_TEMP°C ($CPU2_USAGE%), Max: $MAX_TEMP°C" >> "$LOG_FILE"
  sudo touch /tmp/cpu_temp 2>/dev/null && sudo chmod 644 /tmp/cpu_temp && sudo chown root:root /tmp/cpu_temp
  echo "$MAX_TEMP" > /tmp/cpu_temp && sync || echo "Error: Failed to write to /tmp/cpu_temp"

  # Fan control: Temp + Usage with hysteresis
  if [ "$MAX_TEMP" -ge 55 ] || [ $(echo "$CPU1_USAGE > 75" | bc) -eq 1 ] || [ $(echo "$CPU2_USAGE > 75" | bc) -eq 1 ]; then
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x64
    [ $? -eq 0 ] && echo "Fans set to 100% (~12,000 RPM)" && LAST_SPEED="100" || echo "Failed to set 100%"
  elif [ "$MAX_TEMP" -ge 45 ] || [ $(echo "$CPU1_USAGE > 50" | bc) -eq 1 ] || [ $(echo "$CPU2_USAGE > 50" | bc) -eq 1 ]; then
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x50
    [ $? -eq 0 ] && echo "Fans set to 80% (~9600 RPM)" && LAST_SPEED="80" || echo "Failed to set 80%"
  elif [ "$MAX_TEMP" -ge 40 ] || [ "$USAGE_SPIKE" -eq 1 ] || [ "$LAST_SPEED" = "80" -a "$MAX_TEMP" -ge 35 ]; then
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x3c
    [ $? -eq 0 ] && echo "Fans set to 60% (~7200 RPM) - Pre-cool or hysteresis" && LAST_SPEED="60" || echo "Failed to set 60%"
  elif [ "$MAX_TEMP" -ge 35 ] || [ "$LAST_SPEED" = "60" -a "$MAX_TEMP" -ge 30 ]; then
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x28
    [ $? -eq 0 ] && echo "Fans set to 40% (~4800 RPM)" && LAST_SPEED="40" || echo "Failed to set 40%"
  else
    sudo /usr/bin/ipmitool -I open raw 0x30 0x30 0x02 0xff 0x19
    [ $? -eq 0 ] && echo "Fans set to 25% (~3000 RPM)" && LAST_SPEED="25" || echo "Failed to set 25%"
  fi

  sleep 5
  echo "Current fan speeds:"
  sudo /usr/bin/ipmitool -I open sensor | grep Fan | tee -a "$LOG_FILE"
  sleep 25
done
