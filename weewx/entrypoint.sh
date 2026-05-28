#!/bin/sh
# Entrypoint contract:
#   * first run (no weewx.conf) -> seed /data from the baked station template
#     (/opt/station) and apply the demo configuration (configure.py), then run
#   * called with args          -> forward them to `weectl` (e.g. weectl report)
#   * called with no args       -> run `weewxd`
# The image bakes a fully-extended station template at build time; this script
# materialises it into the bind-mounted /data the first time the stack comes up,
# so `docker compose up` bootstraps end-to-end with no separate install step.
set -eu

WEEWX_ROOT="/data"
CONF="${WEEWX_ROOT}/weewx.conf"

# Honor station.yaml's `station.timezone:` for both configure.py and weewxd.
# Python's `time` / `datetime` read TZ once at process startup, so it has to be
# in the environment BEFORE we exec python/weewxd (configure.py can't set its
# own TZ for a subsequent weewxd process). Falls back to the existing TZ env
# (or container default / UTC) when station.timezone is absent. Empty / missing
# YAML is silently tolerated -- weewxd just runs in whatever TZ it had.
if [ -z "${TZ:-}" ] && [ -f /station.yaml ]; then
  tz="$(python3 -c "
import yaml, sys
try:
    cfg = yaml.safe_load(open('/station.yaml')) or {}
    print((cfg.get('station') or {}).get('timezone') or '', end='')
except Exception:
    sys.exit(0)
" 2>/dev/null || true)"
  if [ -n "$tz" ]; then
    export TZ="$tz"
  fi
fi

if [ "${1:-}" = "--version" ]; then
  exec weewxd --version
fi

if [ ! -f "${CONF}" ]; then
  echo "First run: seeding ${WEEWX_ROOT} from the baked station template."
  cp -a /opt/station/. "${WEEWX_ROOT}/"
  # configure.py reads creds from the environment + config from station.yaml.
  # If it fails, roll back the seeded conf so the next start retries cleanly
  # instead of running an unconfigured (Simulator) station.
  if ! python /configure.py; then
    echo "configure.py failed; rolling back so the next start retries." >&2
    rm -f "${CONF}"
    exit 1
  fi
  echo "Bootstrap complete."
fi

if [ "$#" -gt 0 ]; then
  exec weectl "$@" --config "${CONF}"
else
  exec weewxd --config "${CONF}"
fi
