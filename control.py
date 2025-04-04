#!/usr/bin/env python3
import subprocess
import time
import threading
import logging
import os
import signal
import sys
import psutil
from collections import deque

# Setup
LOG_FILE = "/tmp/r720-fancontrol.log"
USER = "winsock"
IPMITOOL = "/usr/bin/ipmitool"
PID_FILE = "/tmp/r720-fancontrol.pid"
HOLD_TIME = 30  # Seconds to hold speed after trigger
DROP_DELAY = 30  # Seconds to hold speed before any drop
VERSION = "2.42-py"

# Logging
logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format="%(asctime)s - %(message)s", datefmt="%Y-%m-%d %H:%M:%S.%f")
log = logging.getLogger()

# Global state
running = True
usage = 0.0
usage_avg = 0.0
spike_detected = False
spike_size = 0.0
max_temp = 25
last_max_temp = 25
current_speed = 25
cooldown_end = 0
drop_delay_start = 0  # Time when drop condition first detected
last_trigger = {"usage": 0, "temp": 0, "time": 0, "reason": ""}
usage_window = deque(maxlen=25)  # 5s window (25 x 0.2s)
temp_window = deque(maxlen=25)   # 5s temp window
last_usage = 0

def monitor_usage():
    global usage, usage_avg, spike_detected, spike_size, usage_window, last_usage
    while running:
        last_usage = usage
        usage = psutil.cpu_percent(interval=0.2)
        usage_window.append(usage)
        usage_avg = sum(usage_window) / len(usage_window) if usage_window else usage
        spike_size = usage - last_usage
        spike_detected = spike_size > 5
        log.info(f"Usage: {usage:.1f}% (Avg: {usage_avg:.1f}%), Spike: {spike_detected}, Size: {spike_size:.1f}%")
        time.sleep(0.2)

def run_ipmitool(cmd, retries=3, delay=0.5):
    for attempt in range(retries):
        try:
            result = subprocess.run(["sudo", IPMITOOL, "-I", "open"] + cmd.split(), capture_output=True, text=True)
            if result.returncode == 0:
                return True
            log.warning(f"ipmitool attempt {attempt + 1}/{retries} failed: {result.stderr.strip()}")
            time.sleep(delay)
        except subprocess.SubprocessError as e:
            log.warning(f"ipmitool exception on attempt {attempt + 1}/{retries}: {e}")
            time.sleep(delay)
    log.error(f"ipmitool failed after {retries} retries: {cmd}")
    return False

def get_sensor_data():
    try:
        output = subprocess.check_output(["sudo", IPMITOOL, "-I", "open", "sensor"], text=True)
        temps = {}
        for line in output.splitlines():
            parts = [p.strip() for p in line.split("|")]
            if "Inlet Temp" in parts[0]:
                temps["inlet"] = int(float(parts[1]))
            elif "Exhaust Temp" in parts[0]:
                temps["exhaust"] = int(float(parts[1]))
            elif parts[0] == "Temp" and "cpu1" not in temps:
                temps["cpu1"] = int(float(parts[1]))
            elif parts[0] == "Temp":
                temps["cpu2"] = int(float(parts[1]))
        return temps
    except subprocess.CalledProcessError as e:
        log.warning(f"ipmitool sensor failed: {e}")
        return None

def get_fan_rpm():
    try:
        output = subprocess.check_output(
            f"sudo {IPMITOOL} -I open sdr type Fan | grep 'Fan[1-6]' | awk -F'|' '{{sum += $5}} END {{if (NR > 0) print int(sum/NR)}}' | tr -d 'RPM'",
            shell=True, text=True
        )
        return int(output.strip())
    except subprocess.CalledProcessError as e:
        log.warning(f"ipmitool fan RPM failed: {e}")
        return 0

def set_fan_speed(speed):
    hex_speed = {
        25: "0x19",  # ~6000-7000 RPM
        40: "0x28",  # ~8000-9000 RPM
        60: "0x3c",  # ~10000-11000 RPM
        80: "0x50",  # ~12000-13000 RPM
        100: "0x64"  # ~14000+ RPM
    }.get(speed, "0x19")
    return run_ipmitool(f"raw 0x30 0x30 0x02 0xff {hex_speed}")

def notify(direction, speed, rpm, reason, usage, usage_avg, max_temp):
    if direction not in ["Increased", "Decreased"]:
        return  # Only notify on changes
    message = f"Speed {direction.lower()} to {speed}% (~{rpm} RPM) due to {reason}. Current load: {usage:.1f}% (Avg: {usage_avg:.1f}%), Temp: {max_temp}°C. Will hold for {HOLD_TIME}s."
    cmd = [
        "systemd-run", f"--machine={USER}@.host", "--user",
        "dunstify", "-u", "normal", "-t", "10000",
        f"Fan Speed {direction}", message
    ]
    try:
        subprocess.check_call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log.info(f"Sent Dunst notification: {direction} to {speed}%")
    except subprocess.CalledProcessError as e:
        log.warning(f"Dunst notification failed: {e}")

def cleanup_handler(signum, frame):
    global running
    log.info("Shutting down, resetting fan control to auto")
    run_ipmitool("raw 0x30 0x30 0x01 0x01")
    running = False
    os.remove(PID_FILE)
    sys.exit(0)

def main():
    global current_speed, cooldown_end, drop_delay_start, max_temp, last_max_temp, spike_detected, spike_size, temp_window, usage, usage_avg, last_trigger
    signal.signal(signal.SIGTERM, cleanup_handler)
    signal.signal(signal.SIGINT, cleanup_handler)

    if os.path.exists(PID_FILE):
        log.error(f"Script already running with PID {open(PID_FILE).read()}")
        sys.exit(1)
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    log.info(f"Initializing fan control - Version {VERSION}")
    time.sleep(1)
    if not run_ipmitool("raw 0x30 0x30 0x01 0x00"):
        log.error("Failed to enable manual fan control")
        cleanup_handler(None, None)
    if not set_fan_speed(current_speed):
        log.error("Failed to initialize fan speed")
        cleanup_handler(None, None)

    threading.Thread(target=monitor_usage, daemon=True).start()

    while running:
        temps = get_sensor_data()
        if temps:
            max_temp = max(temps["inlet"], temps["exhaust"], temps["cpu1"], temps["cpu2"])
            temp_window.append(max_temp)
            log.info(f"Temps: Inlet {temps['inlet']}°C, Exhaust {temps['exhaust']}°C, CPU1 {temps['cpu1']}°C, CPU2 {temps['cpu2']}°C, Max {max_temp}°C")
            temp_trend = "rising" if len(temp_window) > 1 and max_temp > last_max_temp else "stable" if max_temp == last_max_temp else "falling"
            temp_rate = (max_temp - min(list(temp_window)[-5:])) / 5 if len(temp_window) >= 5 else 0
            last_max_temp = max_temp

        new_speed = current_speed
        reason = ""
        now = time.time()

        # Check spikes first and apply immediately
        if spike_detected:
            if spike_size > 25:
                new_speed = 100
                reason = f"extreme usage spike of {spike_size:.1f}%"
            elif spike_size > 15:
                new_speed = 80
                reason = f"large usage spike of {spike_size:.1f}%"
            elif spike_size > 10:
                new_speed = 60
                reason = f"moderate usage spike of {spike_size:.1f}%"
            else:
                new_speed = 40
                reason = f"small usage spike of {spike_size:.1f}%"
            log.info(f"Spike detected, proposing {new_speed}% for {reason}")
        # Other conditions if no spike
        else:
            if max_temp >= 50:
                new_speed = 100
                reason = f"high temp (Temp: {max_temp}°C >= 50°C)"
                log.info(f"High temp detected, proposing {new_speed}% for {reason}")
            elif max_temp >= 45:
                new_speed = 80
                reason = f"moderate temp (Temp: {max_temp}°C >= 45°C)"
                log.info(f"Moderate temp detected, proposing {new_speed}% for {reason}")
            elif max_temp >= 40:
                new_speed = 60
                reason = f"sustained temp (Temp: {max_temp}°C >= 40°C)"
                log.info(f"Sustained temp detected, proposing {new_speed}% for {reason}")
            elif max_temp >= 30:
                new_speed = 40
                reason = f"idle temp (Temp: {max_temp}°C >= 30°C)"
                log.info(f"Idle temp detected, proposing {new_speed}% for Winsock")
            elif len(temp_window) >= 5 and temp_rate > 0.5:
                new_speed = 80
                reason = f"fast temp rise of {temp_rate:.1f}°C/s"
                log.info(f"Temp rise detected, proposing {new_speed}% for {reason}")
            else:
                new_speed = 25
                reason = f"low temp (Temp: {max_temp}°C < 30°C)"
                log.info(f"Low temp detected, proposing {new_speed}%")

        # Apply speed logic
        if new_speed != current_speed:
            if new_speed > current_speed or (spike_detected and new_speed >= current_speed):  # Immediate increase
                success = set_fan_speed(new_speed)
                if success:
                    log.info(f"Fan speed increased to {new_speed}% (~{get_fan_rpm()} RPM) - Reason: {reason}")
                    current_speed = new_speed
                    cooldown_end = now + HOLD_TIME
                    drop_delay_start = 0
                    last_trigger = {"usage": usage_avg, "temp": max_temp, "time": now, "reason": reason}
                    notify("Increased", current_speed, get_fan_rpm(), reason, usage, usage_avg, max_temp)
                else:
                    log.warning(f"Failed to increase fan speed to {new_speed}%")
                spike_detected = False  # Reset after applying
            else:  # Decrease - enforce delay
                if drop_delay_start == 0:
                    drop_delay_start = now
                    log.info(f"Speed drop to {new_speed}% proposed due to {reason}, starting {DROP_DELAY}s delay")
                elif now - drop_delay_start >= DROP_DELAY and now >= cooldown_end:
                    success = set_fan_speed(new_speed)
                    if success:
                        log.info(f"Fan speed decreased to {new_speed}% (~{get_fan_rpm()} RPM) - Reason: {reason}")
                        current_speed = new_speed
                        cooldown_end = now + HOLD_TIME
                        drop_delay_start = 0
                        last_trigger = {"usage": usage_avg, "temp": max_temp, "time": now, "reason": reason}
                        notify("Decreased", current_speed, get_fan_rpm(), reason, usage, usage_avg, max_temp)
                    else:
                        log.warning(f"Failed to decrease fan speed to {new_speed}%")
                else:
                    remaining_delay = max(0, int(DROP_DELAY - (now - drop_delay_start)))
                    log.info(f"Holding {current_speed}%, drop delay active: {remaining_delay}s left until drop to {new_speed}% due to {reason}")
        else:
            log.info(f"Speed unchanged at {current_speed}%, cooldown active: {int(cooldown_end - now)}s left")
            drop_delay_start = 0  # Reset if speed matches conditions

        spike_detected = False  # Ensure reset after each loop
        time.sleep(1)

if __name__ == "__main__":
    main()