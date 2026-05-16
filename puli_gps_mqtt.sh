#!/bin/sh

# Force full path awareness so the background daemon can find your binaries
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Give the serial bus a moment to clear on service restarts
sleep 3

SECRETS_FILE="/root/puli_gps_secrets"
MODEM_BUS="1-1.2"
SLEEP_INTERVAL=5
MIN_DISTANCE=5.0
MIN_SPEED=1.0

# Load secrets
if [ -f "$SECRETS_FILE" ]; then
    . "$SECRETS_FILE"
else
    exit 1
fi

# Set state directory to track position history across loops
STATE_DIR="/tmp/puli_gps"
mkdir -p "$STATE_DIR"
LAST_LAT_FILE="$STATE_DIR/last_lat"
LAST_LON_FILE="$STATE_DIR/last_lon"

if [ -f "$LAST_LAT_FILE" ] && [ -f "$LAST_LON_FILE" ]; then
    LAST_LAT=$(cat "$LAST_LAT_FILE")
    LAST_LON=$(cat "$LAST_LON_FILE")
else
    LAST_LAT=90
    LAST_LON=0
fi

ensure_gps_on() {
    STATE=$(gl_modem -B "$MODEM_BUS" AT "AT+QGPS?" | grep "+QGPS:" | cut -d' ' -f2 | tr -d '\r\n')
    if [ "$STATE" != "1" ]; then
        gl_modem -B "$MODEM_BUS" AT "AT+QGPS=1" > /dev/null
        sleep 2
    fi
}

should_publish() {
    lat1=$1; lon1=$2; lat2=$3; lon2=$4; speed=$5; min_dist=$6; min_speed=$7
    
    awk -v lat1="$lat1" -v lon1="$lon1" -v lat2="$lat2" -v lon2="$lon2" \
        -v speed="$speed" -v min_dist="$min_dist" -v min_speed="$min_speed" '
    BEGIN {
        if (speed > min_speed) {
            print "1";
            exit;
        }
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

while true; do
    ensure_gps_on
    RAW_DATA=$(gl_modem -B "$MODEM_BUS" AT "AT+QGPSLOC?")
    
    if echo "$RAW_DATA" | grep -q "+QGPSLOC:"; then
        # Clean data stream and completely strip out trailing 'OK' text
        GPS_CSV=$(echo "$RAW_DATA" | sed 's/+QGPSLOC: //g' | tr -d '\r\n ' | sed 's/OK//g')
        
        CUR_LAT=$(echo "$GPS_CSV" | cut -d, -f2)
        CUR_LON=$(echo "$GPS_CSV" | cut -d, -f3)
        CUR_SPD=$(echo "$GPS_CSV" | cut -d, -f8)
        
        if [ -n "$CUR_LAT" ] && [ -n "$CUR_LON" ]; then
            if [ "$(should_publish "$LAST_LAT" "$LAST_LON" "$CUR_LAT" "$CUR_LON" "$CUR_SPD" "$MIN_DISTANCE" "$MIN_SPEED")" -eq 1 ]; then
                T_RAW=$(echo "$GPS_CSV" | cut -d, -f1)
                ALT=$(echo "$GPS_CSV" | cut -d, -f5)
                CRS=$(echo "$GPS_CSV" | cut -d, -f7)
                D_RAW=$(echo "$GPS_CSV" | cut -d, -f10)
                SAT=$(echo "$GPS_CSV" | cut -d, -f11)
                
                # Protect JSON syntax by adding fallback values for empty spaces
                [ -z "$CRS" ] && CRS="0.0"
                [ -z "$ALT" ] && ALT="0.0"
                [ -z "$SAT" ] && SAT="0"
                [ -z "$CUR_SPD" ] && CUR_SPD="0.0"
                
                # Native OpenWrt Ash string slicing for stable timestamp formatting
                YEAR=$(echo "$D_RAW" | cut -c5-6)
                MONTH=$(echo "$D_RAW" | cut -c3-4)
                DAY=$(echo "$D_RAW" | cut -c1-2)
                
                HR=$(echo "$T_RAW" | cut -c1-2)
                MIN=$(echo "$T_RAW" | cut -c3-4)
                SEC=$(echo "$T_RAW" | cut -c5-6)
                
                TS="20${YEAR}-${MONTH}-${DAY}T${HR}:${MIN}:${SEC}Z"
                
                # Build valid JSON (wrapping values in quotes ensures safety)
                PAYLOAD="{\"ts\":\"$TS\",\"lat\":\"$CUR_LAT\",\"lon\":\"$CUR_LON\",\"alt\":$ALT,\"speed\":$CUR_SPD,\"course\":$CRS,\"sat\":$SAT}"
                
                if mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$MQTT_TOPIC" -m "$PAYLOAD"; then
                    echo "$CUR_LAT" > "$LAST_LAT_FILE"
                    echo "$CUR_LON" > "$LAST_LON_FILE"
                    LAST_LAT=$CUR_LAT
                    LAST_LON=$CUR_LON
                    echo "[$(date +%T)] MQTT Update Sent (Speed: $CUR_SPD km/h)"
                fi
            fi
        fi
    fi
    sleep "$SLEEP_INTERVAL"
done
