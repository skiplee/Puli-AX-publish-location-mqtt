#!/bin/sh
# PID file guard
PIDFILE="/var/run/puli_gps_mqtt.pid"
if [ -f "$PIDFILE" ]; then
  if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "Already running (PID $(cat $PIDFILE)). Exiting." >&2
    exit 0
  else
    rm -f "$PIDFILE"
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; exit' INT TERM EXIT

# puli_gps_mqtt.sh - GNSS init + safe polling + troubleshooting mode
# Secrets file must define MQTT_HOST MQTT_USER MQTT_PASS MQTT_TOPIC
. /root/puli_gps_secrets

# ===== Configuration =====
GPS_DEV="/dev/ttyUSB2"
INTERVAL=5            # poll interval in seconds (used in troubleshooting mode)
HEARTBEAT=300         # publish at least this often (seconds)
STATE_FILE="/tmp/last_gps"
LOG="/tmp/gps_poll.log"

# 1 = publish every INTERVAL regardless of filters; 0 = normal behavior
TROUBLESHOOTING=1     

GNSS_INIT_INTERVAL=300 # re-run GNSS init every N seconds

# ===== Helpers =====
publish() {
  mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$MQTT_TOPIC" -m "$1"
}

distance_m() {
  LAT1=$1 LON1=$2 LAT2=$3 LON2=$4
  awk -v lat1="$LAT1" -v lon1="$LON1" -v lat2="$LAT2" -v lon2="$LON2" '
    function rad(x){return x*3.1415926535/180}
    {
      dlat = rad(lat2-lat1)
      dlon = rad(lon2-lon1)
      a = sin(dlat/2)^2 + cos(rad(lat1))*cos(rad(lat2))*sin(dlon/2)^2
      c = 2*atan2(sqrt(a), sqrt(1-a))
      print 6371000*c
    }'
}

# Non-blocking read for +QGPSLOC (arg = seconds to wait for grep)
safe_read_qgpsloc() {
  TIMEOUT_SEC=${1:-3}
  RAW=$(timeout "$TIMEOUT_SEC" grep -m 1 "+QGPSLOC" "$GPS_DEV" 2>/dev/null)
  if [ -n "$RAW" ]; then
    echo "$RAW"
    return 0
  fi
  BYTES=$(timeout 1 dd if="$GPS_DEV" bs=1 count=256 2>/dev/null)
  echo "$BYTES" | grep -m 1 "+QGPSLOC" 2>/dev/null || true
}

# ===== GNSS init (use the verified start command) =====
init_gnss() {
  echo "$(date -Is) GNSS init" >> "$LOG"
  # disable echo, enable GNSS, give modem a short settle time
  echo -e "ATE0\r" > "$GPS_DEV"
  sleep 0.2
  echo -e "AT+QGPS=1\r" > "$GPS_DEV"
  sleep 1
  # quick confirm (non-blocking)
  echo -e "AT+QGPS?\r" > "$GPS_DEV"
  timeout 1 dd if="$GPS_DEV" bs=1 count=128 2>/dev/null | hexdump -C >> "$LOG" 2>/dev/null || true
}

# ===== Device holder check =====
device_held_by() {
  for pid in $(ls /proc | grep -E '^[0-9]+$'); do
    if ls -l /proc/$pid/fd 2>/dev/null | grep -q "$(basename $GPS_DEV)"; then
      tr '\0' ' ' < /proc/$pid/cmdline
      return 0
    fi
  done
  return 1
}

# ===== Start =====
echo "START $(date -Is)" >> "$LOG"
init_gnss
LAST_HEARTBEAT=$(date +%s)
LAST_GNSS_INIT=$(date +%s)

# ===== Main loop =====
while true; do
  NOW=$(date +%s)

  # periodic GNSS re-init
  if [ $((NOW - LAST_GNSS_INIT)) -ge $GNSS_INIT_INTERVAL ]; then
    init_gnss
    LAST_GNSS_INIT=$NOW
  fi

  # skip if device held
  HOLDER=$(device_held_by)
  if [ -n "$HOLDER" ]; then
    echo "$(date -Is) device held by: $HOLDER" >> "$LOG"
    sleep "$INTERVAL"
    continue
  fi

  # request a location (non-blocking)
  echo -e "AT+QGPSLOC=2\r" > "$GPS_DEV"
  RAW=$(safe_read_qgpsloc 3)

  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  NOW=$(date +%s)

  if [ -z "$RAW" ] || echo "$RAW" | grep -q "+QGPSLOC: 0"; then
    publish "{\"ts\":\"$TS\",\"fix\":0,\"lat\":null,\"lon\":null,\"alt\":null,\"speed\":null,\"course\":null,\"sat\":0}"
    echo "$(date -Is) NO FIX or empty response" >> "$LOG"
    sleep "$INTERVAL"
    continue
  fi

  # parse QGPSLOC fields
  LAT=$(echo "$RAW" | cut -d',' -f2)
  LON=$(echo "$RAW" | cut -d',' -f3)
  ALT=$(echo "$RAW" | cut -d',' -f5)
  FIX=$(echo "$RAW" | cut -d',' -f6)
  SPEED=$(echo "$RAW" | cut -d',' -f8)
  COURSE=$(echo "$RAW" | cut -d',' -f9)
  SAT=$(echo "$RAW" | cut -d',' -f11)

  # troubleshooting mode: publish every INTERVAL
  if [ "$TROUBLESHOOTING" -eq 1 ]; then
    publish "{\"ts\":\"$TS\",\"lat\":$LAT,\"lon\":$LON,\"alt\":$ALT,\"fix\":$FIX,\"speed\":$SPEED,\"course\":$COURSE,\"sat\":$SAT}"
    echo "$(date -Is) PUBLISHED (troubleshoot) $LAT,$LON fix=$FIX sat=$SAT" >> "$LOG"
    sleep "$INTERVAL"
    continue
  fi

  # normal filters: require 3D fix and minimum satellites
  if [ "$FIX" -ne 3 ] || [ "$SAT" -lt 4 ]; then
    publish "{\"ts\":\"$TS\",\"fix\":0,\"lat\":null,\"lon\":null,\"alt\":null,\"speed\":null,\"course\":null,\"sat\":$SAT}"
    echo "$(date -Is) insufficient fix sat=$SAT fix=$FIX" >> "$LOG"
    sleep "$INTERVAL"
    continue
  fi

  # load last point and apply movement/implausible jump filters
  SHOULD_PUBLISH=false
  if [ -f "$STATE_FILE" ]; then
    LAST_LAT=$(cut -d',' -f1 "$STATE_FILE")
    LAST_LON=$(cut -d',' -f2 "$STATE_FILE")
    LAST_TIME=$(cut -d',' -f3 "$STATE_FILE")
    DIST=$(distance_m "$LAST_LAT" "$LAST_LON" "$LAT" "$LON")
    DT=$((NOW - LAST_TIME))
    [ "$DT" -lt 1 ] && DT=1
    IMP_MS=$(awk -v d="$DIST" -v t="$DT" 'BEGIN{print d/t}')
    IMP_KPH=$(awk -v v="$IMP_MS" 'BEGIN{print v*3.6}')
    if awk "BEGIN{exit !($IMP_KPH > 300)}"; then
      echo "$(date -Is) impossible jump: $IMP_KPH kph" >> "$LOG"
      sleep "$INTERVAL"
      continue
    fi
    MOVED=$(awk "BEGIN{exit !($DIST > 5)}"; echo $?)
    FAST=$(awk "BEGIN{exit !($SPEED > 1)}"; echo $?)
    if [ "$MOVED" = 0 ] || [ "$FAST" = 0 ]; then
      SHOULD_PUBLISH=true
    fi
  else
    SHOULD_PUBLISH=true
  fi

  # heartbeat
  if [ $((NOW - LAST_HEARTBEAT)) -ge $HEARTBEAT ]; then
    SHOULD_PUBLISH=true
    LAST_HEARTBEAT=$NOW
  fi

  if [ "$SHOULD_PUBLISH" = true ]; then
    publish "{\"ts\":\"$TS\",\"lat\":$LAT,\"lon\":$LON,\"alt\":$ALT,\"fix\":$FIX,\"speed\":$SPEED,\"course\":$COURSE,\"sat\":$SAT}"
    echo "$LAT,$LON,$NOW" > "$STATE_FILE"
    echo "$(date -Is) PUBLISHED $LAT,$LON fix=$FIX sat=$SAT" >> "$LOG"
  fi

  sleep "$INTERVAL"
done
