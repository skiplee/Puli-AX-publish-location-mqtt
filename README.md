# Puli AX (GL-XE3000) GPS to MQTT Location Publisher

A lightweight, robust, and hardened POSIX shell daemon designed for OpenWrt to extract high-accuracy GNSS telemetry data from the native internal Quectel modem bus on the GL.iNet Puli AX (GL-XE3000) and publish it to a local or remote MQTT broker. 

This script is purpose-built for mobile environments (camper vans, overland vehicles) to feed clean, jitter-filtered tracking data directly into Home Assistant instances without relying on third-party cloud tracking platforms.

## Features

- **Hardware-Enforced Fix Validation:** Bypasses basic satellite-counting guess-work. Uses native AT engine parameters to require an explicit **3D Triangulation Lock** (FIX_MODE=3) and a configurable **HDOP** threshold to completely filter out tree-canopy drift, split-constellation "ghost fixes", and initial cold-start location jumps.
- **Dual-Trigger Spatial Pipeline:** Optimizes cellular and network bandwidth by evaluating spatial state changes through a low-overhead, inline awk tracking engine.
  - **Speed Trigger:** Automatically fires updates when tracking velocity exceeds a minimum threshold (MIN_SPEED).
  - **Distance Trigger:** Uses flat decimal geometry calculations to compute movement from the last successfully published coordinates (MIN_DISTANCE).
- **Resilient Heartbeat Fallback:** Transmits a diagnostic payload periodically (HEARTBEAT_INTERVAL) even if stationary or if the GPS fix drops out. This allows Home Assistant to continuously evaluate hardware health and cellular state connectivity.
- **Deadlock Hardening:** Every internal hardware interaction is wrapped in binary execution limits via timeout boundaries. If the modem's serial AT channel stalls or crashes due to ambient heat or cellular carrier switches, the daemon auto-recovers gracefully without hanging.
- **Zero-Dependency Core:** Implemented entirely using core POSIX utilities (sh, awk, sed) natively present on minimalist embedded OpenWrt systems.

## Architecture & Logic Flow

1. **Flush & Loop Initializations:** At the start of every iteration loop, the local variable space is completely zeroed to prevent historical or stale memory segments from polluting a failed read.
2. **Hardware Diagnostics Query:** The script uses timeout to safely issue an AT+QGPSLOC? instruction to the underlying multi-constellation Quectel baseband hardware module.
3. **Hardware-Level Filtering:** If coordinates are returned, awk parses out the structural components and executes an input-cleaning pass (+ 0 numeric masks). It forces data validation parameters to match high accuracy rules (FIX_MODE == 3 and HDOP <= 5.0).
4. **Distance & Core Speed Evaluation:** If valid, the position is compared with LAST_LAT` and LAST_LON parameters. If a distance or speed delta is broken, PUBLISH_TRIGGER trips.
5. **JSON Package Serialization:** Telemetry is bundled into a predictable JSON payload. If a hardware fix is missing during a mandatory heartbeat interval, coordinate parameters are serialized explicitly as null values to keep downstream systems from freezing on stale location artifacts.

## MQTT Payload Specifications

### Valid 3D Fix Payload Example:
```
{
  "ts": "2026-05-19T21:15:30Z",
  "lat": 47.812345,
  "lon": -122.345678,
  "alt": 112.4,
  "speed": 45.5,
  "course": 182.3,
  "sat": 14,
  "hdop": 1.2,
  "fix": 3,
  "status": "Valid 3D GPS Fix"
}
```

### Diagnostic Heartbeat Payload (No Lock) Example:
```
{
  "ts": "2026-05-19T21:20:30Z",
  "lat": null,
  "lon": null,
  "alt": 0.0,
  "speed": 0.0,
  "course": 0.0,
  "sat": 2,
  "hdop": 23.4,
  "fix": 2,
  "status": "Poor Geometry / High Jitter (HDOP: 23.4)"
}
```

## Prerequisites & Dependencies

The following packages must be present on your OpenWrt firmware (available via opkg):
- gl-modem (GL.iNet proprietary AT command bridge utility)
- mosquitto-client (Provides the binary mosquitto_pub CLI execution agent)
- coreutils-timeout (Provides strict command termination protections)

## Installation & Setup

1. Clone or drop the core script payload (puli_gps_mqtt.sh) into /root/ or your preferred binary subdirectory. Make sure it has proper execution privileges:
   chmod +x /root/puli_gps_mqtt.sh

2. Establish an independent environment secrets definition target at /root/puli_gps_secrets. This file isolates your private operational tokens from git synchronization processes:
```   
   MQTT_HOST="YOUR_BROKER_IP"
   MQTT_PORT="1883"
   MQTT_USER="your_mqtt_username"
   MQTT_PASS="your_mqtt_password"
   MQTT_TOPIC="puli/gps/location"
```

4. To maintain persistence across reboots, initialize the daemon execution pathway by appending the process command to the end of your standard /etc/rc.local file (placed right above the exit 0 baseline statement):
   /root/puli_gps_mqtt.sh > /dev/null 2>&1 &

## Configuration Tuning Variables

You can open puli_gps_mqtt.sh and fine-tune your parameters directly at the head of the file:

SLEEP_INTERVAL=5        # Hardware sampling frequency in seconds
MIN_DISTANCE=5.0        # Physical movement required to update location (in meters)
MIN_SPEED=1.0           # Speed threshold required to bypass distance calculations (in km/h)
HEARTBEAT_INTERVAL=300  # Enforced logging telemetry period (in seconds)
MAX_HDOP=5.0            # Maximum allowed geometric error threshold (lower is tighter precision)

## Home Assistant Integration Example

Home Assistant handles incoming JSON payloads elegantly. Unknown keys (like hdop or fix) will be silently ignored until you decide to pull them into your UI cards using explicit helper configurations.

To process this stream, add the matching tracking variables into your Home Assistant environment configurations (configuration.yaml):

mqtt:
  device_tracker:
    - name: "Puli Router"
      unique_id: "puli_router_tracker"
      state_topic: "puli/gps/location"
      json_attributes_topic: "puli/gps/location"
      payload_available: "online"
      source_type: "gps"

  sensor:
    - name: "Puli Router Speed"
      unique_id: "puli_router_speed"
      state_topic: "puli/gps/location"
      value_template: "{{ value_json.speed | float(0.0) }}"
      unit_of_measurement: "km/h"
      device_class: "speed"

    - name: "Puli GPS Signal Status"
      unique_id: "puli_gps_signal_status"
      state_topic: "puli/gps/location"
      value_template: "{{ value_json.status }}"
      icon: "mdi:text-diagnostic"

## My deployment script

It's not the most elegant; I ssh into the Puli and paste this snippet:

```
# fetch the service script and the main script from your repo (raw URLs)
curl -fsSL https://raw.githubusercontent.com/skiplee/Puli-AX-publish-location-mqtt/main/puli_gps -o /etc/init.d/puli_gps
curl -fsSL https://raw.githubusercontent.com/skiplee/Puli-AX-publish-location-mqtt/main/puli_gps_mqtt.sh -o /root/puli_gps_mqtt.sh

# make executable, enable at boot, and start now
chmod +x /etc/init.d/puli_gps /root/puli_gps_mqtt.sh
/etc/init.d/puli_gps enable
/etc/init.d/puli_gps restart 

# quick verification
sleep 4
ps | grep puli_gps_mqtt.sh | grep -v grep || true
logread | tail -n 50
```

If needed, I run this in an HA terminal to monitor for messages because I find the MQTT ui to be misleading at times.

```
mosquitto_sub -h homeassistant -t puli/# -v
```
