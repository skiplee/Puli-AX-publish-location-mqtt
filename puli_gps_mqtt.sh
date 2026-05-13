#!/bin/sh

# ============================
# Load secrets (not in GitHub)
# ============================
. /root/puli_gps_secrets

# ============================
# Configuration
# ============================
GPS_DEV="/dev/ttyUSB2"
INTERVAL=5 # how frequently to publish location, in seconds
HEARTBEAT=300 # publish interval in seconds, even if filters reduce volume.
STATE_FILE="/tmp/last_gps"

# ============================
# Helper: publish JSON
# ============================
publish() {
    mosquitto_pub \
        -h "$MQTT_HOST" \
        -u "$MQTT_USER" \
        -P "$MQTT_PASS" \
        -t "$MQTT_TOPIC" \
        -m "$1"
}

# ============================
# Distance function (meters)
# ============================
distance_m() {
    LAT1=$1
    LON1=$2
    LAT2=$3
    LON2=$4

    awk -v lat1="$LAT1" -v lon1="$LON1" -v lat2="$LAT2" -v lon2="$LON2" '
        function rad(x){return x*3.1415926535/180}
        {
            dlat = rad(lat2-lat1)
            dlon = rad(lon2-lon1)
            a = sin(dlat/2)^2 + cos(rad(lat1))*cos(rad(lat2))*sin(dlon/2)^2
            c = 2*atan2(sqrt(a), sqrt(1-a))
            print 6371000*c
        }
    '
}

LAST_HEARTBEAT=$(date +%s)

# ============================
# Main loop
# ============================
while true; do
    # Request GPS fix
    echo -e "AT+QGPSLOC=2\r" > "$GPS_DEV"
    sleep 0.2

    RAW=$(timeout 1 grep -m 1 "+QGPSLOC" "$GPS_DEV")
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    NOW=$(date +%s)

    # ----------------------------
    # No fix or empty response
    # ----------------------------
    if [ -z "$RAW" ] || echo "$RAW" | grep -q "+QGPSLOC: 0"; then
        publish "{\"ts\":\"$TS\",\"fix\":0,\"lat\":null,\"lon\":null,\"alt\":null,\"speed\":null,\"course\":null,\"sat\":0}"
        sleep "$INTERVAL"
        continue
    fi

    # ----------------------------
    # Parse fields
    # ----------------------------
    LAT=$(echo "$RAW" | cut -d',' -f2)
    LON=$(echo "$RAW" | cut -d',' -f3)
    ALT=$(echo "$RAW" | cut -d',' -f5)
    FIX=$(echo "$RAW" | cut -d',' -f6)
    SPEED=$(echo "$RAW" | cut -d',' -f8)     # kph
    COURSE=$(echo "$RAW" | cut -d',' -f9)
    SAT=$(echo "$RAW" | cut -d',' -f11)

    # ----------------------------
    # Good fix requirement
    # ----------------------------
    if [ "$FIX" -ne 3 ] || [ "$SAT" -lt 4 ]; then
        publish "{\"ts\":\"$TS\",\"fix\":0,\"lat\":null,\"lon\":null,\"alt\":null,\"speed\":null,\"course\":null,\"sat\":$SAT}"
        sleep "$INTERVAL"
        continue
    fi

    # ----------------------------
    # Load last good point if exists
    # ----------------------------
    if [ -f "$STATE_FILE" ]; then
        LAST_LAT=$(cut -d',' -f1 "$STATE_FILE")
        LAST_LON=$(cut -d',' -f2 "$STATE_FILE")
        LAST_TIME=$(cut -d',' -f3 "$STATE_FILE")

        DIST=$(distance_m "$LAST_LAT" "$LAST_LON" "$LAT" "$LON")
        DT=$((NOW - LAST_TIME))
        [ "$DT" -lt 1 ] && DT=1

        IMP_MS=$(awk -v d="$DIST" -v t="$DT" 'BEGIN{print d/t}')
        IMP_KPH=$(awk -v v="$IMP_MS" 'BEGIN{print v*3.6}')

        # ----------------------------
        # Impossible jump filter
        # ----------------------------
        if awk "BEGIN{exit !($IMP_KPH > 300)}"; then
            sleep "$INTERVAL"
            continue
        fi

        # ----------------------------
        # Movement threshold
        # ----------------------------
        MOVED=$(awk "BEGIN{exit !($DIST > 5)}")
        FAST=$(awk "BEGIN{exit !($SPEED > 1)}")

        SHOULD_PUBLISH=false
        if [ "$MOVED" = "0" ] || [ "$FAST" = "0" ]; then
            SHOULD_PUBLISH=true
        fi
    else
        SHOULD_PUBLISH=true
        DIST=0
        IMP_KPH=0
    fi

    # ----------------------------
    # Heartbeat every threshold
    # ----------------------------
    if [ $((NOW - LAST_HEARTBEAT)) -ge $HEARTBEAT ]; then
        SHOULD_PUBLISH=true
        LAST_HEARTBEAT=$NOW
    fi

    # ----------------------------
    # Publish if needed
    # ----------------------------
    if [ "$SHOULD_PUBLISH" = true ]; then
        publish "{\"ts\":\"$TS\",\"lat\":$LAT,\"lon\":$LON,\"alt\":$ALT,\"fix\":$FIX,\"speed\":$SPEED,\"course\":$COURSE,\"sat\":$SAT}"
        echo "$LAT,$LON,$NOW" > "$STATE_FILE"
    fi

    sleep "$INTERVAL"
done
