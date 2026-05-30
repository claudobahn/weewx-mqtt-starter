#!/usr/bin/env bash
# Health check for the running stack -- a pass/fail summary, CI-friendly (exits
# non-zero on failure). Run after `./setup.sh` (or `docker compose up`).
#
# Adapts to the running mode (read from data/weewx.conf):
#   * demo (Simulator driver): data must flow -> dashboard 200 + weather/loop
#     are required.
#   * template (MQTTSubscribe driver): there's no data source until you connect a
#     real OMG, so those are informational (use ./e2e-test.sh to prove the
#     pipeline, or bring up the demo layer to see live data).
# Works against the base, demo, and prod layers.
set -uo pipefail
cd "$(dirname "$0")"
DC="docker compose"

[ -f .env ] && { set -a; . ./.env; set +a; }

station_type="$(grep -iE '^[[:space:]]*station_type' data/weewx.conf 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*//')"
case "$station_type" in Simulator*) DEMO=1; MODE="demo (Simulator)";; *) DEMO=0; MODE="template (MQTTSubscribe)";; esac

pass=0 fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '       %s\n' "$1"; }

echo "== mode: ${MODE} =="

echo "== services running =="
state="$($DC ps --format '{{.Service}} {{.State}}' 2>/dev/null)"
for svc in mqtt weewx web; do
  echo "$state" | grep -q "^${svc} running" && ok "$svc running" || no "$svc not running"
done

echo "== weewx engine =="
logs="$($DC logs weewx 2>&1)"
# NB: bash pattern match (not `echo "$logs" | grep -q`). With `set -o pipefail`,
# grep -q exits 0 on the first match and closes the pipe; the still-writing
# `echo` then dies with SIGPIPE (141), and pipefail propagates that as the
# pipeline status -- so once `docker compose logs weewx` outgrows the pipe
# buffer (~64 KB, after a handful of restarts), this check spuriously failed.
[[ "$logs" == *"Loading station type"* ]] \
  && ok "engine loaded station driver" || no "engine did not load a station driver"
errs="$(echo "$logs" | grep -c 'ERROR' || true)"
if [ "$errs" -eq 0 ]; then ok "no ERROR lines in weewx log"; else
  no "$errs ERROR line(s) in weewx log"
  echo "$logs" | grep 'ERROR' | tail -3 | sed 's/^/       /'
fi

echo "== broker auth =="
anon="$($DC exec -T mqtt mosquitto_sub -t weather/loop -C 1 -W 2 2>&1 || true)"
echo "$anon" | grep -qi "not authorised" \
  && ok "anonymous connection rejected" || no "anonymous NOT rejected (got: ${anon:-<empty>})"

echo "== data on weather/loop =="
if [ -n "${MQTT_DASH_USER:-}" ] && [ -n "${MQTT_DASH_PASS:-}" ]; then
  feed="$($DC exec -T mqtt mosquitto_sub -u "$MQTT_DASH_USER" -P "$MQTT_DASH_PASS" \
            -t weather/loop -C 1 -W 8 2>&1 || true)"
  if echo "$feed" | grep -q "outTemp_F"; then
    ok "weather/loop is publishing data"
  elif [ "$DEMO" -eq 1 ]; then
    no "no data on weather/loop (the Simulator demo should be publishing)"
  else
    note "weather/loop quiet -- expected for the template with no data source"
    note "(connect a real OMG, run ./e2e-test.sh, or use the demo layer)"
  fi
else
  note "MQTT_DASH_USER/PASS not in .env -- skipping feed check"
fi

echo "== dashboard =="
if command -v curl >/dev/null 2>&1; then
  code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/ 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    ok "dashboard returns HTTP 200"
  elif [ "$DEMO" -eq 1 ]; then
    no "dashboard returned HTTP ${code:-<none>} (demo should have a report)"
  elif [ "$code" = "000" ] || [ -z "$code" ]; then
    no "web server not responding"
  else
    ok "web server responding (HTTP $code)"
    note "no report yet (HTTP $code) -- expected until data arrives"
  fi
else
  note "curl not found -- skipping dashboard check"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mAll %d checks passed.\033[0m\n' "$pass"
else
  printf '\033[31m%d passed, %d FAILED.\033[0m\n' "$pass" "$fail"
  exit 1
fi
