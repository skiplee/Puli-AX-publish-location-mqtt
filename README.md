
# Puli GPS → MQTT Tracker

This project provides a lightweight GPS tracking script for the **GL‑iNet Puli (OpenWrt‑based)** router.  
It reads GNSS data from the Quectel modem, filters out bad fixes and impossible jumps, and publishes clean location updates to an MQTT broker (e.g., Home Assistant).

The script is designed to run **24/7**, survive reboots, and automatically restart using OpenWrt’s `procd` service manager.

---

## Features

- Reads GPS data from the modem using `AT+QGPSLOC=2`
- Requires a **good fix** (3D fix + minimum satellite count)
- Filters out **impossible jumps** (e.g., 200‑mile glitches)
- Publishes only when:
  - distance moved > **5 meters**, or  
  - speed > **1 kph**
- Sends a **heartbeat every 60 seconds**
- Stores MQTT credentials in a **separate secrets file**
- Runs automatically at boot via a **procd service**

---

## File Structure

```
/root/puli_gps_mqtt.sh        # Main script (safe for GitHub)
/root/puli_gps_secrets        # Credentials (NOT in GitHub)
/etc/init.d/puli_gps          # Service definition
```

---

## 1. Install the GPS Script

SSH into the Puli:

```
ssh root@192.168.8.1
```

Create the script:

```
vi /root/puli_gps_mqtt.sh
```

Paste the full script from this repository.

Save and exit:

```
ESC
:wq
```

Make it executable:

```
chmod +x /root/puli_gps_mqtt.sh
```
Or; pull it from github and install it directly (again in ssh terminal)

```
# fetch updated script and make executable
curl -fsSL https://raw.githubusercontent.com/skiplee/Puli-AX-publish-location-mqtt/main/puli_gps_mqtt.sh -o /root/puli_gps_mqtt.sh
chmod +x /root/puli_gps_mqtt.sh
```

---

## 2. Create the Secrets File

Create:

```
vi /root/puli_gps_secrets
```

Add your MQTT settings:

```
MQTT_HOST="homeassistant"
MQTT_USER="youruser"
MQTT_PASS="yourpass"
MQTT_TOPIC="puli/gps"
```

Save:

```
ESC
:wq
```

Lock down permissions:

```
chmod 600 /root/puli_gps_secrets
```

> **Important:**  
> Do **not** commit this file to GitHub.

---

## 3. Install the Service

Create the service file:

```
vi /etc/init.d/puli_gps
```

Paste:

```
#!/bin/sh /etc/rc.common

START=99
STOP=01

USE_PROCD=1
SERVICE_NAME="puli_gps"

start_service() {
    procd_open_instance
    procd_set_param command /root/puli_gps_mqtt.sh
    procd_set_param respawn 5000 1 0
    procd_close_instance
}
```

Save:

```
ESC
:wq
```

Make executable:

```
chmod +x /etc/init.d/puli_gps
```

Enable at boot:

```
/etc/init.d/puli_gps enable
```

Start immediately:

```
/etc/init.d/puli_gps start
```

---

## 4. Verify Operation

Check that the script is running:

```
ps | grep puli_gps_mqtt
```

Watch MQTT messages from Home Assistant:

```
mosquitto_sub -h homeassistant -t puli/# -v
```

You should see:

- movement‑based updates  
- heartbeat every 60 seconds  
- no garbage jumps  
- no noise while parked  

---

## 5. Updating the Script

Any time you modify `/root/puli_gps_mqtt.sh`, restart the service:

```
/etc/init.d/puli_gps restart
