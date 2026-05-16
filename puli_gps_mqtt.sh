#!/bin/sh

# --- Configuration & Secrets ---
SECRETS_FILE="/root/puli_gps_secrets"
MODEM_BUS="1-1.2"
SLEEP_INTERVAL=10
MIN_DISTANCE=5.0
MIN_SPEED=1.0

# Load Secrets
if [ -f "$SECRETS_FILE" ]; then
    . "$SECRETS_FILE"
else
    exit 1
fi

# --- State Variables ---
LAST_LAT=90
LAST_LON=0

# --- Helper: Decision Engine ---
# Returns 1 if thresholds are met, 0 otherwise
should_publish() {
    awk -v lat1="$1" -v lon1="$2" -v lat2="$3" -v lon2="$4" \
        -v speed="$5" -v min_dist="$6" -v min_speed="$7" 'BEGIN {
        # Speed trigger (Fastest check)
        if (speed > min_speed) {
            print "1"; 
            exit;
        }

        # Distance trigger (Trig check)
        PI = 3.1415926535;
        deg2meters = 111319;
        rad = lat2 * (PI / 180);
        lonscl = cos(rad);
        dy = (lat2 - lat1) * deg2meters;
        dx = (lon2 - lon1) * deg2meters * lonscl;
        dist = sqrt((dx*dx) + (dy*dy));
        
        if (dist >= min_dist) print "1";
        else print "0";
    }'
}

ensure_gps_on() {
    STATE=$(gl_modem -B "$MODEM_BUS" AT AT+QGPS? | grep "+QGPS:" | cut -d' ' -f2 | tr -d '\r\n')
    if [ "$STATE" != "1" ]; then
        gl_modem -B "$MODEM_BUS" AT AT+QGPS=1 > /dev/null
        sleep 2
    fi
}

# --- Main Loop ---
while true; do
    ensure_gps_on
    RAW_DATA=$(gl_modem -B "$MODEM_BUS" AT AT+QGPSLOC?)

    if echo "$RAW_DATA" | grep -q "+QGPSLOC:"; then
        GPS_CSV=$(echo "$RAW_DATA" | sed 's/+QGPSLOC: //g' | tr -d '\r\n ')
        CUR_LAT=$(echo "$GPS_CSV" | cut -d',' -f2)
        CUR_LON=$(echo "$GPS_CSV" | cut -d',' -f3)
        CUR_SPD=$(echo "$GPS_CSV" | cut -d',' -f8)

        if [ -n "$CUR_LAT" ] && [ -n "$CUR_LON" ]; then
            # Binary decision: 1 or 0
            if [ "$(should_publish "$LAST_LAT" "$LAST_LON" "$CUR_LAT" "$CUR_LON" "$CUR_SPD" "$MIN_DISTANCE" "$MIN_SPEED")" -eq 1 ]; then
                
                # Only parse these if we are actually sending the message
                T_RAW=$(echo "$GPS_CSV" | cut -d',' -f1)
                ALT=$(echo "$GPS_CSV" | cut -d',' -f5)
                CRS=$(echo "$GPS_CSV" | cut -d',' -f7)
                D_RAW=$(echo "$GPS_CSV" | cut -d',' -f10)
                SAT=$(echo "$GPS_CSV" | cut -d',' -f11)

                # ISO 8601 Timestamp
                TS="20${D_RAW:4:2}-${D_RAW:2:2}-${D_RAW:0:2}T${T_RAW:0:2}:${T_RAW:2:2}:${T_RAW:4:2}Z"
                
                PAYLOAD="{\"ts\":\"$TS\",\"lat\":$CUR_LAT,\"lon\":$CUR_LON,\"alt\":$ALT,\"speed\":$CUR_SPD,\"course\":$CRS,\"sat\":$SAT}"
                
                if mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$MQTT_TOPIC" -m "$PAYLOAD"; then
                    LAST_LAT=$CUR_LAT
                    LAST_LON=$CUR_LON
                    echo "[$(date +%T)] MQTT Update Sent (Speed: $CUR_SPD km/h)"
                fi
            fi
        fi
    fi
    sleep "$SLEEP_INTERVAL"
done
