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
MAX_HDOP=5.0           # Maximum allowed geometric error (lower is more accurate)

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
    STATE=$(timeout 3 gl_modem -B "$MODEM_BUS" AT "AT+QGPS?" 2>/dev/null | grep "+QGPS:" | cut -d' ' -f2 | tr -d '\r\n')
    if [ "$STATE" != "1" ]; then
        timeout 3 gl_modem -B "$MODEM_BUS" AT "AT+QGPS=1" > /dev/null 2>&1
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

        print (dist >= min_dist) ? "1" : "0";
    }'
}

while true; do
    ensure_gps_on
    
    RAW_DATA=$(timeout 4 gl_modem -B "$MODEM_BUS" AT "AT+QGPSLOC?" 2>/dev/null)
    
    # CRITICAL HARDENING: Flush old variables out of shell memory completely
    CUR_LAT=""; CUR_LON=""; CUR_SPD="0.0"; ALT="0.0"; CRS="0.0"; SAT="0"; CUR_HDOP="99.9"; FIX_MODE="0"
    HAVE_FIX=0
    PUBLISH_TRIGGER=0
    DIAG_STATUS="No Signal"
    
    if echo "$RAW_DATA" | grep -q "+QGPSLOC:"; then
        # ## Clean data stream and completely strip out trailing 'OK' text
        GPS_CSV=$(echo "$RAW_DATA" | sed 's/+QGPSLOC: //g' | tr -d '\r\n ' | sed 's/OK//g')

        # ## Parse and convert NMEA to Decimal Degrees immediately 
        CONVERTED=$(echo "$GPS_CSV" | awk -F, -v max_hdop="$MAX_HDOP" '{
            raw_lat = $2; raw_lon = $3; hdop = $4; alt = $5; fix_mode = $6; course = $7; speed = $8; sat = $11;
            
            if (length(raw_lat) < 4 || length(raw_lon) < 4) {
                printf "CUR_LAT=;CUR_LON=;FIX_MODE=0;CUR_HDOP=99.9;";
                exit;
            }
            
            sgn_lat = (raw_lat ~ /S/) ? -1 : 1;
            sgn_lon = (raw_lon ~ /W/) ? -1 : 1;
            
            gsub(/[^0-9.]/, "", raw_lat);
            gsub(/[^0-9.]/, "", raw_lon);
            gsub(/[^0-9.]/, "", sat);
            gsub(/[^0-9.]/, "", hdop);
            gsub(/[^0-9.]/, "", fix_mode);
            
            match(raw_lat, /\./); lat_dot = RSTART;
            match(raw_lon, /\./); lon_dot = RSTART;
            
            dec_lat = (substr(raw_lat, 1, lat_dot-3) + (substr(raw_lat, lat_dot-2) / 60)) * sgn_lat;
            dec_lon = (substr(raw_lon, 1, lon_dot-3) + (substr(raw_lon, lon_dot-2) / 60)) * sgn_lon;
            
            clean_sat = (sat == "") ? 0 : sat + 0;
            clean_alt = (alt == "") ? "0.0" : alt;
            clean_crs = (course == "") ? "0.0" : course;
            clean_hdop = (hdop == "") ? 99.9 : hdop + 0.0;
            clean_fix = (fix_mode == "") ? 0 : fix_mode + 0;
            
            printf "CUR_LAT=%.6f;CUR_LON=%.6f;CUR_SPD=%.1f;SAT=%d;ALT=%s;CRS=%s;CUR_HDOP=%.1f;FIX_MODE=%d;", 
                dec_lat, dec_lon, speed, clean_sat, clean_alt, clean_crs, clean_hdop, clean_fix;
        }')
        eval "$CONVERTED"
        
        if [ -n "$CUR_LAT" ] && [ -n "$CUR_LON" ]; then
            if [ "$FIX_MODE" -eq 3 ] && [ "$(echo "$CUR_HDOP <= $MAX_HDOP" | bc 2>/dev/null || awk -v h="$CUR_HDOP" -v m="$MAX_HDOP" 'BEGIN {print (h<=m)?1:0}')" -eq 1 ]; then
                HAVE_FIX=1
                DIAG_STATUS="Valid 3D GPS Fix"
                PUBLISH_TRIGGER=$(should_publish "$LAST_LAT" "$LAST_LON" "$CUR_LAT" "$CUR_LON" "$CUR_SPD" "$MIN_DISTANCE" "$MIN_SPEED")
            else
                if [ "$FIX_MODE" -ne 3 ]; then
                    DIAG_STATUS="Acquiring 3D Math Lock (Fix Mode: $FIX_MODE)"
                else
                    DIAG_STATUS="Poor Geometry / High Jitter (HDOP: $CUR_HDOP)"
                fi
            fi
        fi
    elif echo "$RAW_DATA" | grep -q "+CME ERROR:"; then
        ERR_CODE=$(echo "$RAW_DATA" | grep -o "[0-9]\+")
        DIAG_STATUS="Modem Error $ERR_CODE (Searching/No Fix)"
    elif echo "$RAW_DATA" | grep -q "ERROR" || [ -z "$RAW_DATA" ]; then
        DIAG_STATUS="Modem Channel Stalled/Plain Error"
    fi
    
    PUBLISH_TRIGGER=$([ "$TIMER" -ge "$HEARTBEAT_INTERVAL" ] ? echo "1" : echo "$PUBLISH_TRIGGER")
    
    if [ "$PUBLISH_TRIGGER" -eq 1 ]; then
        if [ "$HAVE_FIX" -eq 1 ]; then
            D_RAW=$(echo "$GPS_CSV" | cut -d, -f10)
            T_RAW=$(echo "$GPS_CSV" | cut -d, -f1)
            
            YEAR=$(echo "$D_RAW" | cut -c5-6)
            MONTH=$(echo "$D_RAW" | cut -c3-4)
            DAY=$(echo "$D_RAW" | cut -c1-2)
            HR=$(echo "$T_RAW" | cut -c1-2)
            MIN=$(echo "$T_RAW" | cut -c3-4)
            SEC=$(echo "$T_RAW" | cut -c5-6)
            
            TS="20${YEAR}-${MONTH}-${DAY}T${HR}:${MIN}:${SEC}Z"
            PAYLOAD="{\"ts\":\"$TS\",\"lat\":$CUR_LAT,\"lon\":$CUR_LON,\"alt\":$ALT,\"speed\":$CUR_SPD,\"course\":$CRS,\"sat\":$SAT,\"hdop\":$CUR_HDOP,\"fix\":$FIX_MODE,\"status\":\"$DIAG_STATUS\"}"
        else
            TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            PAYLOAD="{\"ts\":\"$TS\",\"lat\":null,\"lon\":null,\"alt\":0.0,\"speed\":0.0,\"course\":0.0,\"sat\":$SAT,\"hdop\":$CUR_HDOP,\"fix\":$FIX_MODE,\"status\":\"$DIAG_STATUS\"}"
        fi
        
        if mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$MQTT_TOPIC" -m "$PAYLOAD"; then
            if [ "$HAVE_FIX" -eq 1 ]; then
                LAST_LAT=$CUR_LAT
                LAST_LON=$CUR_LON
                echo "[$(date +%T)] MQTT Update Sent. Status: $DIAG_STATUS ($CUR_SPD km/h)"
            else
                echo "[$(date +%T)] MQTT Diagnostic Heartbeat Sent. Status: $DIAG_STATUS"
            fi
            TIMER=0 
        else
            echo "[$(date +%T)] WARNING: MQTT Publish Failed (Broker Offline). Retrying on next loop."
        fi
    fi
    
    sleep "$SLEEP_INTERVAL"
    
    TIMER=$(( TIMER + SLEEP_INTERVAL ))
    TIMER=$(( TIMER > HEARTBEAT_INTERVAL ? HEARTBEAT_INTERVAL : TIMER ))
done
