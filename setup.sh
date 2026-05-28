#!/usr/bin/env bash
# Bootstrap for the WeeWX + MQTT + fuzzy-archer docker-compose stack.
#
# This script only prepares host-side state, then brings the stack up:
#   * generates the MQTT account passwords into the gitignored .env
#   * builds the Mosquitto password file from them
#   * builds the WeeWX image and `docker compose up`
# The WeeWX install itself -- station + the three pinned extensions -- is baked
# into the image at build time (see weewx/Dockerfile) and seeded into ./data by
# the container on first run (weewx/entrypoint.sh + configure.py), so there are
# no install steps here. If your Docker host needs an HTTP proxy, set it once in
# ~/.docker/config.json ("proxies"); Docker injects it into the image build
# automatically, so there's nothing proxy-related in this repo.
#
# Re-running is safe: credentials are reused from .env and the container skips
# bootstrap once ./data/weewx.conf exists.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
DC="docker compose"

# Mosquitto image for the one-off password-hashing container below. Derived from
# docker-compose.yml so the pin lives in exactly one place (the mqtt service).
MOSQUITTO_IMAGE="$(docker compose config --images mqtt 2>/dev/null | head -n1)"
[ -n "${MOSQUITTO_IMAGE}" ] || { echo "setup.sh: could not read the mqtt image from docker-compose.yml" >&2; exit 1; }

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# Load local config (.env): generated MQTT creds, optional WEEWX_VERSION override.
[ -f .env ] && { set -a; . ./.env; set +a; }

# --- MQTT credentials (generated once, persisted in the gitignored .env) -----
# Three least-privilege accounts (see mosquitto/acl). Passwords are generated on
# first run and reused thereafter, so the password file and weewx.conf stay in
# sync across re-runs.
# Subshell with pipefail off: `head` closing the pipe makes `tr` exit with
# SIGPIPE (141), which would otherwise abort the script under `set -o pipefail`.
rand() { ( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 24 ); }
ensure_env() {  # name [value]  -> if unset, set (generate when value omitted) + persist to .env
  local name="$1" val
  eval "val=\${$name:-}"
  if [ -z "$val" ]; then
    val="${2:-$(rand)}"
    printf '%s=%s\n' "$name" "$val" >> .env
    export "$name=$val"
  fi
}
say "Ensuring MQTT credentials (.env)"
touch .env
ensure_env MQTT_OMG_USER omg
ensure_env MQTT_WEEWX_USER weewx
ensure_env MQTT_DASH_USER dashboard
ensure_env MQTT_HEALTH_USER health       # internal: only the mqtt service's healthcheck
ensure_env MQTT_OMG_PASS
ensure_env MQTT_WEEWX_PASS
ensure_env MQTT_DASH_PASS
ensure_env MQTT_HEALTH_PASS

say "Building the Mosquitto password file"
# Write user:pass lines, then hash them in place with `mosquitto_passwd -U`
# (keeps plaintext off any process argv).
printf '%s:%s\n%s:%s\n%s:%s\n%s:%s\n' \
  "$MQTT_OMG_USER" "$MQTT_OMG_PASS" \
  "$MQTT_WEEWX_USER" "$MQTT_WEEWX_PASS" \
  "$MQTT_DASH_USER" "$MQTT_DASH_PASS" \
  "$MQTT_HEALTH_USER" "$MQTT_HEALTH_PASS" > mosquitto/passwd
docker run --rm --user root -v "${ROOT}/mosquitto:/m" "$MOSQUITTO_IMAGE" \
  sh -c 'mosquitto_passwd -U /m/passwd && chmod 644 /m/passwd'

# --- build the WeeWX image (station + pinned extensions baked in) -----------
say "Building the WeeWX image (weewx==${WEEWX_VERSION:-5.3.1}; extensions + paho-mqtt + ephem + pyyaml baked in)"
$DC build weewx

# --- data dir owned by the container's weewx user (uid 1000) ----------------
say "Preparing ./data (owned by uid 1000)"
mkdir -p data
docker run --rm -v "${ROOT}/data:/data" alpine:3.22 sh -c 'chown -R 1000:1000 /data'

# --- bring up the stack; WeeWX self-bootstraps on first run -----------------
# On first start the weewx container seeds ./data from the baked station
# template and runs configure.py (creds + sensor map from .env / sensors.yaml);
# thereafter it just runs weewxd. mqtt-ui stays opt-in (the `tools` profile).
say "Starting the stack (first run bootstraps WeeWX automatically)"
$DC up -d --remove-orphans

# Wait for the first-run bootstrap (the container seeds ./data + runs
# configure.py); weewx.conf appears once it's done.
say "Waiting for first-run bootstrap"
for _ in $(seq 1 36); do
  [ -f data/weewx.conf ] && break
  sleep 5
done
[ -f data/weewx.conf ] || echo "WARNING: bootstrap not complete; check 'docker compose logs weewx'."

# --- mode-aware finish ------------------------------------------------------
# A data source only exists in the demo (Simulator) layer; the bare template
# waits for a real OMG. Only block on the first report when data will flow.
station_type="$(grep -iE '^[[:space:]]*station_type' data/weewx.conf 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*//' || true)"

case "$station_type" in
  Simulator*)
    say "Waiting for the first report (up to ~3 min)"
    for _ in $(seq 1 36); do
      [ -f data/public_html/index.html ] && break
      sleep 5
    done
    [ -f data/public_html/index.html ] && echo "Report generated." \
      || echo "WARNING: report not generated yet; check 'docker compose logs weewx'."
    cat <<EOF

Done -- demo (Simulator driver).
  Dashboard : http://localhost:8080/   (public, read-only; live synthetic data)
  MQTT      : 127.0.0.1:1883 / ws://127.0.0.1:9001  -- auth required, creds in ./.env

Watch live data:
  set -a; . ./.env; set +a
  docker compose exec mqtt mosquitto_sub -u "\$MQTT_DASH_USER" -P "\$MQTT_DASH_PASS" -t weather/loop -v
Health check: ./verify.sh
Logs:         docker compose logs -f weewx
EOF
    ;;
  *)
    cat <<EOF

Done -- base template (MQTTSubscribe driver).
  Dashboard : http://localhost:8080/   (public, read-only)
  MQTT      : 127.0.0.1:1883 / ws://127.0.0.1:9001  -- auth required, creds in ./.env
              (omg=publish, weewx=engine, dashboard=read-only)

No data source is running, so the dashboard stays empty until data arrives:
  See it live now (Simulator demo):
    docker compose down && rm -rf data mosquitto/data
    COMPOSE_FILE=docker-compose.yml:docker-compose.demo.yml ./setup.sh
  Use real hardware: point your OpenMQTTGateway at this broker, then edit
    sensors.yaml (see README "Using a real OpenMQTTGateway device").
  Test the pipeline end-to-end: ./e2e-test.sh

Health check: ./verify.sh
MQTT UI (opt-in): docker compose --profile tools up -d mqtt-ui   # http://localhost:8083
Logs: docker compose logs -f weewx
EOF
    ;;
esac
