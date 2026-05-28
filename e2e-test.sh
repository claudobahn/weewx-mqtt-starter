#!/usr/bin/env bash
# End-to-end test of the real rtl_433 -> MQTTSubscribe -> publish pipeline.
#
# Injects OpenMQTTGateway-shaped rtl_433 JSON (a Fine Offset WS80 + an
# AmbientWeather WH31B) into the broker as the `omg` account, then asserts the
# readings round-trip onto `weather/loop` as gauge-ready keys (outTemp_F,
# extraTemp1_F). This exercises the actual driver + field mapping (station.yaml)
# + weewx-mqtt/publish path -- the part the Simulator-driver demo bypasses.
#
# Run against the base template (MQTTSubscribe driver) with the stack up:
#   ./setup.sh && ./e2e-test.sh
# NOTE: it publishes real readings, so a few synthetic records land in the
# archive DB -- run it before pointing the stack at production data.
set -uo pipefail
cd "$(dirname "$0")"
DC="docker compose"

[ -f .env ] && { set -a; . ./.env; set +a; }

fail() { printf '\033[31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }

# --- guards -----------------------------------------------------------------
[ -f data/weewx.conf ] || fail "data/weewx.conf not found -- run ./setup.sh first."
grep -qiE '^[[:space:]]*station_type[[:space:]]*=[[:space:]]*MQTTSubscribeDriver' data/weewx.conf \
  || fail "this test needs the MQTTSubscribe driver (the base template). The demo's Simulator driver bypasses the MQTT pipeline."
state="$($DC ps --format '{{.Service}} {{.State}}' 2>/dev/null)"
echo "$state" | grep -q "^mqtt running"  || fail "mqtt not running -- run ./setup.sh first."
echo "$state" | grep -q "^weewx running" || fail "weewx not running -- run ./setup.sh first."
: "${MQTT_OMG_USER:?MQTT_OMG_USER not in .env}" "${MQTT_DASH_USER:?MQTT_DASH_USER not in .env}"

OMG="home/OMG_sim/RTL_433toMQTT"
WS80_TOPIC="${OMG}/Fineoffset-WS80/204"
WH31B_TOPIC="${OMG}/AmbientWeather-WH31B/12"

pub() {  # topic json  -- publish as the omg (publish-only) account
  $DC exec -T mqtt mosquitto_pub -u "$MQTT_OMG_USER" -P "$MQTT_OMG_PASS" -t "$1" -m "$2" \
    || fail "publish to $1 failed (broker/auth?)"
}

echo "== injecting WS80 + WH31B and capturing weather/loop (up to ~25s) =="
cap="$(mktemp)"
# Subscribe first (background) so we catch the round-tripped loop packets.
$DC exec -T mqtt mosquitto_sub -u "$MQTT_DASH_USER" -P "$MQTT_DASH_PASS" \
  -t weather/loop -W 25 > "$cap" 2>&1 &
subpid=$!
sleep 1

i=0
while [ "$i" -lt 6 ]; do
  tc=$(awk -v i="$i" 'BEGIN{printf "%.1f", 15+2*i}')   # vary the readings a little
  it=$(awk -v i="$i" 'BEGIN{printf "%.1f", 18+i}')
  pub "$WS80_TOPIC"  "{\"model\":\"Fineoffset-WS80\",\"id\":204,\"battery_ok\":1,\"temperature_C\":${tc},\"humidity\":62,\"wind_avg_m_s\":3.1,\"wind_max_m_s\":4.6,\"wind_dir_deg\":210,\"uvi\":4,\"light_lux\":48000,\"mic\":\"CRC\"}"
  pub "$WH31B_TOPIC" "{\"model\":\"AmbientWeather-WH31B\",\"id\":12,\"channel\":1,\"battery_ok\":1,\"temperature_C\":${it},\"humidity\":47,\"data\":\"8f00000000\",\"mic\":\"CRC\",\"protocol\":\"Ambient Weather WH31E Thermo-Hygrometer\",\"rssi\":-44,\"duration\":52992}"
  i=$((i + 1))
  sleep 2
done

wait "$subpid" 2>/dev/null
echo "  captured $(grep -c . "$cap" 2>/dev/null || echo 0) weather/loop message(s)"

rc=0
if grep -q "outTemp_F" "$cap"; then
  printf '  \033[32mPASS\033[0m WS80 round-trip (outTemp_F on weather/loop)\n'
else
  printf '  \033[31mFAIL\033[0m WS80 reading did not reach weather/loop\n'; rc=1
fi
if grep -q "extraTemp1_F" "$cap"; then
  printf '  \033[32mPASS\033[0m WH31B round-trip (extraTemp1_F on weather/loop)\n'
else
  printf '  \033[31mFAIL\033[0m WH31B reading did not reach weather/loop\n'; rc=1
fi
rm -f "$cap"

echo
if [ "$rc" -eq 0 ]; then
  printf '\033[32mE2E pipeline OK: rtl_433 JSON -> MQTTSubscribe -> weather/loop.\033[0m\n'
else
  printf '\033[31mE2E pipeline FAILED.\033[0m  See: docker compose logs weewx\n'
fi
exit "$rc"
