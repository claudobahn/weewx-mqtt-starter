#!/bin/sh
# Synthetic MAST buoy publisher -- emits realistic JSON to home/buoy/mast as
# the `omg` MQTT account so the MQTTSubscribe driver consumes it as if real
# firmware were publishing. Use on the mast-buoy branch until actual firmware
# (or a bridge) publishes to the same topic; then stop / remove this service.
set -eu

HOST="${MQTT_HOST:-mqtt}"
TOPIC="${MQTT_TOPIC:-home/buoy/mast}"
INTERVAL="${INTERVAL:-16}"          # publish cadence in seconds (rtl_433-like)
AUTH=""
[ -n "${MQTT_USER:-}" ] && AUTH="-u ${MQTT_USER} -P ${MQTT_PASS}"

echo "mast-publisher: emitting MAST buoy data to ${HOST} ${TOPIC} every ${INTERVAL}s"

i=0
while true; do
  # Realistic MAST buoy readings, varied with sine waves indexed by i.
  set -- $(awk -v i="$i" 'BEGIN {
    wavg = 8 + 6*sin(i/20.0);    if (wavg < 0) wavg = 0;
    wmax = wavg + 3;
    wdir = (i*7) % 360;
    wht  = 1.5 + 1.0*sin(i/15.0); if (wht < 0) wht = 0.1;
    wper = 5 + 2*sin(i/25.0);
    cspd = 0.5 + 0.4*sin(i/12.0); if (cspd < 0) cspd = 0;
    cdir = (i*11 + 90) % 360;
    glat = 43.036583 + 0.0001*sin(i/40.0);
    glon = -87.846067 + 0.0001*cos(i/40.0);
    rssi = -75 + 5*sin(i/30.0);
    snr  = 5 + 3*sin(i/22.0);
    wtemp = 50 + 5*sin(i/50.0);
    printf "%.1f %.1f %d %.2f %.1f %.2f %d %.5f %.5f %.0f %.1f %.0f",
           wavg, wmax, wdir, wht, wper, cspd, cdir, glat, glon, rssi, snr, wtemp;
  }')
  wavg=$1; wmax=$2; wdir=$3; wht=$4; wper=$5
  cspd=$6; cdir=$7; glat=$8; glon=$9
  rssi=${10}; snr=${11}; wtemp=${12}

  msg="{\"windSpeed_kn\":${wavg},\"windGust_kn\":${wmax},\"windDir\":${wdir},\"waveHeight_ft\":${wht},\"wavePeriod_s\":${wper},\"currentSpeed_kn\":${cspd},\"currentDir\":${cdir},\"gpsLat\":${glat},\"gpsLon\":${glon},\"rxRSSI\":${rssi},\"rxSNR\":${snr},\"waterTemp\":${wtemp}}"

  mosquitto_pub -h "${HOST}" ${AUTH} -t "${TOPIC}" -m "${msg}" \
    || echo "mast-publisher: publish failed (broker not ready?)"

  i=$((i + 1))
  sleep "${INTERVAL}"
done
