#!/bin/sh

# Force full path awareness so the background daemon can find your binaries
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# Give the modem serial interface a moment to clear on service restarts
sleep 3

SECRETS_FILE="/root/puli_gps_secrets"
MODEM_BUS="1-1.2"
SLEEP_INTERVAL=5
MIN_DISTANCE=5.0
MIN_SPEED=1.0
HEARTBEAT_INTERVAL=300 # 5 minutes in seconds

# Load secrets
if [ -f "$SECRETS_FILE" ]; then
    . "$SECRETS_FILE"
else
    exit 1
fi

# In-memory initialization only. Every restart forces a publish.
LAST_LAT=90
LAST_LON=0
TIMER=0 # Tracks seconds elapsed since the last successful MQTT publish

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
        # Speed trigger (Fastest check)
        if (speed > min_speed) {
            print "1";
            exit;
        }

        # Distance trigger (Trig check using flat decimal inputs)
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
    
    # Initialize state flags for this cycle
    HAVE_FIX=0
    PUBLISH_TRIGGER=0
    
    if echo "$RAW_DATA" | grep -q "+QGPSLOC:"; then
        # Clean data stream and completely strip out trailing 'OK' text
        GPS_CSV=$(echo "$RAW_DATA" | sed 's/+QGPSLOC: //g' | tr -d '\r\n ' | sed 's/OK//g')
        
        # Parse and convert NMEA to Decimal Degrees immediately
        CONVERTED=$(echo "$GPS_CSV" | awk -F, '{
            raw_lat = $2; raw_lon = $3; speed = $8;
            
            # Guard against cold-start or empty data streams
            if (length(raw_lat) < 4 || length(raw_lon) < 4) {
                printf "CUR_LAT=;CUR_LON=;CUR_SPD=0.0;";
                exit;
            }
            
            sgn_lat = (raw_lat ~ /S/) ? -1 : 1;
            sgn_lon = (raw_lon ~ /W/) ? -1 : 1;
            
            gsub(/[^0-9.]/, "", raw_lat);
            gsub(/[^0-9.]/, "", raw_lon);
            
            match(raw_lat, /\./); lat_dot = RSTART;
            match(raw_lon, /\./); lon_dot = RSTART;
            
            dec_lat = (substr(raw_lat, 1, 2) + (substr(raw_lat, lat_dot-2) / 60)) * sgn_lat;
            dec_lon = (substr(raw_lon, 1, 3) + (substr(raw_lon, lon_dot-2) / 60)) * sgn_lon;
            
            printf "CUR_LAT=%.6f;CUR_LON=%.6f;CUR_SPD=%.1f;", dec_lat, dec_lon, speed;
        }')
        eval "$CONVERTED"
        
        if [ -n "$CUR_LAT" ] && [ -n "$CUR_LON" ]; then
            HAVE_FIX=1
            # Evaluate spatial filters
            PUBLISH_TRIGGER=$(should_publish "$LAST_LAT" "$LAST_LON" "$CUR_LAT" "$CUR_LON" "$CUR_SPD" "$MIN_DISTANCE" "$MIN_SPEED")
        fi
    fi
    
    # Heartbeat threshold override (Runs even if HAVE_FIX=0 or RAW_DATA failed)
    if [ "$TIMER" -ge "$HEARTBEAT_INTERVAL" ]; then
        PUBLISH_TRIGGER=1
    fi
    
    if [ "$PUBLISH_TRIGGER" -eq 1 ]; then
        if [ "$HAVE_FIX" -eq 1 ]; then
            # Build healthy payload with valid coordinates
            T_RAW=$(echo "$GPS_CSV" | cut -d, -f1)
            ALT=$(echo "$GPS_CSV" | cut -d, -f5)
            CRS=$(echo "$GPS_CSV" | cut -d, -f7)
            D_RAW=$(echo "$GPS_CSV" | cut -d, -f10)
            SAT=$(echo "$GPS_CSV" | cut -d, -f11)
            
            [ -z "$CRS" ] && CRS="0.0"
            [ -z "$ALT" ] && ALT="0.0"
            [ -z "$SAT" ] && SAT="0"
            [ -z "$CUR_SPD" ] && CUR_SPD="0.0"
            
            YEAR=$(echo "$D_RAW" | cut -c5-6)
            MONTH=$(echo "$D_RAW" | cut -c3-4)
            DAY=$(echo "$D_RAW" | cut -c1-2)
            HR=$(echo "$T_RAW" | cut -c1-2)
            MIN=$(echo "$T_RAW" | cut -c3-4)
            SEC=$(echo "$T_RAW" | cut -c5-6)
            
            TS="20${YEAR}-${MONTH}-${DAY}T${HR}:${MIN}:${SEC}Z"
            PAYLOAD="{\"ts\":\"$TS\",\"lat\":$CUR_LAT,\"lon\":$CUR_LON,\"alt\":$ALT,\"speed\":$CUR_SPD,\"course\":$CRS,\"sat\":$SAT}"
        else
            # Build a telemetry diagnostic payload (Valid JSON, but null coordinates)
            TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            PAYLOAD="{\"ts\":\"$TS\",\"lat\":null,\"lon\":null,\"alt\":0.0,\"speed\":0.0,\"course\":0.0,\"sat\":0}"
        fi
        
        if mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$MQTT_TOPIC" -m "$PAYLOAD"; then
            if [ "$HAVE_FIX" -eq 1 ]; then
                LAST_LAT=$CUR_LAT
                LAST_LON=$CUR_LON
                
                if [ "$TIMER" -ge "$HEARTBEAT_INTERVAL" ]; then
                    echo "[$(date +%T)] MQTT Heartbeat Sent (Threshold Reached)"
                else
                    echo "[$(date +%T)] MQTT Update Sent (Movement: $CUR_SPD km/h)"
                fi
            else
                echo "[$(date +%T)] MQTT Diagnostic Heartbeat Sent (No GPS Fix)"
            fi
            
            TIMER=0 # Reset tracking clock on successful network publication
        fi
    fi
    
    sleep "$SLEEP_INTERVAL"
    
    # Ternary syntax math execution to advance clock and cap it at threshold
    TIMER=$(( TIMER + SLEEP_INTERVAL ))
    TIMER=$(( TIMER > HEARTBEAT_INTERVAL ? HEARTBEAT_INTERVAL : TIMER ))
done
