#!/bin/sh
# Synthetic MCSC weather-station publisher -- emits realistic rtl_433-shaped
# JSON for four real-hardware-equivalent devices (Fine Offset WS90 primary
# station, Fine Offset WH57 lightning detector, AmbientWeather-WH31B backup
# outdoor temp/humidity, Fine Offset WH32B dedicated barometer), one
# mosquitto_pub per device per tick. The topic
# names follow the OMG (OpenMQTTGateway) convention
# `home/<gateway-id>/RTL_433toMQTT/<model>/<id>` that station.yaml's sensors
# block subscribes to via `home/+/RTL_433toMQTT/<model>/+`.
#
# Stand-in for real hardware: once an OMG receiver (or any rtl_433 publisher
# on the LAN) starts emitting on the same topics, stop / remove this service.
#
# Payload fields are the raw rtl_433 decoder names (temperature_C, humidity,
# wind_avg_m_s, ...) -- units come from station.yaml's per-field declarations
# so the values match whatever a real device would emit.
set -eu

HOST="${MQTT_HOST:-mqtt}"
INTERVAL="${INTERVAL:-16}"          # publish cadence in seconds (rtl_433-like)
AUTH=""
[ -n "${MQTT_USER:-}" ] && AUTH="-u ${MQTT_USER} -P ${MQTT_PASS}"

# Topic prefix: 'mcsc-gw' stands in for the OMG hostname that would publish
# in a real deployment. The trailing numeric ID matches each device's serial.
# Note: the WH57 product is decoded by rtl_433 under the model name
# "FineOffset-WH31L" (not Fineoffset-WH57); topic + payload model match that.
TOPIC_WS90="home/mcsc-gw/RTL_433toMQTT/Fineoffset-WS90/12345"
TOPIC_WH57="home/mcsc-gw/RTL_433toMQTT/FineOffset-WH31L/67890"
# WH31B is multi-channel, so OMG includes the channel as an extra topic
# level: .../AmbientWeather-WH31B/<channel>/<id>. Use channel 1 = backup
# outdoor sensor (the per-channel field map in station.yaml gates on _1).
TOPIC_WH31B="home/mcsc-gw/RTL_433toMQTT/AmbientWeather-WH31B/1/24680"
# WH32B: dedicated barometric pressure sensor. The real WS90 at MCSC has no
# baro, so station pressure comes from this separate device (its temperature_C
# /humidity are its own sheltered readings, left unmapped in station.yaml).
TOPIC_WH32B="home/mcsc-gw/RTL_433toMQTT/Fineoffset-WH32B/79"

echo "mcsc-publisher: emitting WS90+WH57+WH31B+WH32B rtl_433-shape to ${HOST} every ${INTERVAL}s"

i=0
rain_total=0      # WS90 rain_mm is cumulative (contains_total: true)
strike_total=0    # WH57 strike_count is cumulative

while true; do
  # Lake Michigan summer-ish conditions, sine-varied; rain accumulates in
  # bursts; lightning fires rarely. awk does the math and emits the values
  # in a fixed order for shell to pick up.
  set -- $(awk -v i="$i" -v rt="$rain_total" -v st="$strike_total" 'BEGIN {
    srand(i);
    # WS90 -- primary station
    temp_c   = 20 + 5*sin(i/45.0);                          # ~15-25 C
    hum      = 65 + 18*sin(i/35.0);  if (hum<30) hum=30; if (hum>98) hum=98;
    pressure = 1013 + 7*sin(i/80.0);                        # hPa, ~1006-1020
    wavg_kn  = 9 + 7*sin(i/20.0);    if (wavg_kn<0) wavg_kn=0;
    wmax_kn  = wavg_kn + 3 + 4*rand();
    wavg_ms  = wavg_kn * 0.5144;                            # knots -> m/s
    wmax_ms  = wmax_kn * 0.5144;
    wdir     = int((i*7 + 180 + 20*sin(i/15.0)) % 360);
    if (wdir<0) wdir+=360;
    # UV + light_lux diurnal half-cosine on a 144-tick (~38 min) day cycle.
    # light_lux peaks ~100k lux (bright sun); WS90 emits raw lux.
    day_t    = (i % 144) / 144.0;
    envelope = 1 - (2*day_t - 1)*(2*day_t - 1);
    if (envelope<0) envelope=0;
    uvi      = 9      * envelope;
    light    = 100000 * envelope;
    # Rain bursts: ~10 ticks of rain every 200 ticks (~53 min cycle)
    cycle = i % 200;
    if (cycle >= 50 && cycle < 60) rt += 0.25;              # rain_mm cumulative
    # WH57: lightning fires once every ~150 ticks, distance 8-16 km
    if (i>0 && i%150 == 0) st += 1;
    storm_dist = 8 + int(8*rand());
    # WH32B baro -- its own sheltered enclosure reading: warmer + drier than
    # the outdoor WS90 (these are unmapped in station.yaml; only pressure is used).
    wh_temp = temp_c + 6.0;
    wh_hum  = hum - 22;  if (wh_hum<15) wh_hum=15;
    printf "%.1f %.0f %.1f %.2f %.2f %d %.1f %.0f %.2f %d %d %.1f %.0f",
           temp_c, hum, pressure, wavg_ms, wmax_ms, wdir, uvi, light, rt, st, storm_dist, wh_temp, wh_hum;
  }')
  temp_c=$1; hum=$2; pressure=$3; wavg_ms=$4; wmax_ms=$5; wdir=$6
  uvi=$7; light=$8; rain_total=$9; strike_total=${10}; storm_dist=${11}
  wh_temp=${12}; wh_hum=${13}

  # WS90: wind / temp / humidity / UV / light / rain. No pressure_hPa -- the
  # real MCSC WS90 has no baro sensor (see TOPIC_WH32B below).
  mosquitto_pub -h "${HOST}" ${AUTH} -t "${TOPIC_WS90}" \
    -m "{\"model\":\"Fineoffset-WS90\",\"id\":12345,\"temperature_C\":${temp_c},\"humidity\":${hum},\"wind_avg_m_s\":${wavg_ms},\"wind_max_m_s\":${wmax_ms},\"wind_dir_deg\":${wdir},\"uvi\":${uvi},\"light_lux\":${light},\"rain_mm\":${rain_total},\"battery_ok\":1}" \
    || echo "mcsc-publisher: WS90 publish failed (broker not ready?)"

  # WH57 (decoded as FineOffset-WH31L): heartbeat emission with current
  # strike_count + last storm distance. storm_dist_km is the last-known value
  # on quiet ticks (matches the real radio's behavior).
  mosquitto_pub -h "${HOST}" ${AUTH} -t "${TOPIC_WH57}" \
    -m "{\"model\":\"FineOffset-WH31L\",\"id\":67890,\"strike_count\":${strike_total},\"storm_dist_km\":${storm_dist},\"battery_ok\":1}" \
    || echo "mcsc-publisher: WH57 publish failed"

  # WH31B channel 1: backup outdoor temp/humidity (same numbers as WS90 here
  # for simplicity; a real WH31B would lag slightly + read a different
  # micro-climate).
  mosquitto_pub -h "${HOST}" ${AUTH} -t "${TOPIC_WH31B}" \
    -m "{\"model\":\"AmbientWeather-WH31B\",\"id\":24680,\"channel\":1,\"temperature_C\":${temp_c},\"humidity\":${hum},\"battery_ok\":1}" \
    || echo "mcsc-publisher: WH31B publish failed"

  # WH32B: dedicated barometer. pressure_hPa -> station `pressure`; weewx's
  # StdWXCalculate derives the sea-level `barometer` from it + altitude +
  # outTemp. temperature_C/humidity are the sensor's own (unmapped) readings.
  mosquitto_pub -h "${HOST}" ${AUTH} -t "${TOPIC_WH32B}" \
    -m "{\"model\":\"Fineoffset-WH32B\",\"id\":79,\"temperature_C\":${wh_temp},\"humidity\":${wh_hum},\"pressure_hPa\":${pressure},\"battery_ok\":1,\"mic\":\"CRC\"}" \
    || echo "mcsc-publisher: WH32B publish failed"

  i=$((i + 1))
  sleep "${INTERVAL}"
done
