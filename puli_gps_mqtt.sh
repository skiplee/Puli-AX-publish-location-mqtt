#!/bin/sh

# Force full path awareness so the background daemon can find your binaries
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Give the serial bus a moment to clear on service restarts
sleep 3

SECRETS_FILE="/root/puli_gps_secrets"
MODEM_BUS="1-1.2"
SLEEP_INTERVAL=5

# Load secrets
if [ -f "$SECRETS_FILE" ]; then
    . "$SECRETS_FILE"
else
    exit 1
fi

ensure_gps_on() {
    STATE=$(gl_modem -B "$MODEM_BUS" AT "AT+QGPS?" | grep "+QGPS:" | cut -d' ' -f2 | tr -d '\r\n')
    if [ "$STATE" != "1" ]; then
        gl_modem -B "$MODEM_BUS" AT "AT+QGPS=1" > /dev/null
        sleep 2
    fi
}

while true; do
    ensure_gps_on
    
    # Grab the raw line from the modem
    RAW_DATA=$(gl_modem -B "$MODEM_BUS" AT "AT+QGPSLOC?")
    
    # If the modem successfully gave us a coordinate string, send it raw
    if echo "$RAW_DATA" | grep -q "+QGPSLOC:"; then
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$MQTT_TOPIC" -m "$RAW_DATA"
    fi
    
    sleep "$SLEEP_INTERVAL"
done
