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
else
  # Auto-apply station.yaml on restart when it has changed since the last
  # apply. configure.py writes /data/.station-yaml.hash on success (both at
  # first-run bootstrap and via scripts/apply.sh), so comparing hashes here
  # detects edits cheaply. If configure.py fails, keep the previous conf and
  # let weewxd run -- the user can fix the YAML and restart again.
  if [ -f /station.yaml ]; then
    current_hash="$(sha256sum /station.yaml | awk '{print $1}')"
    applied_hash="$(cat "${WEEWX_ROOT}/.station-yaml.hash" 2>/dev/null || true)"
    if [ "${current_hash}" != "${applied_hash}" ]; then
      echo "station.yaml changed since last apply; re-running configure.py."
      if ! python /configure.py; then
        echo "WARNING: configure.py failed; keeping previous weewx.conf." >&2
        echo "         Fix station.yaml and restart, or run scripts/apply.sh." >&2
      fi
    fi
  fi
fi

if [ "$#" -gt 0 ]; then
  exec weectl "$@" --config "${CONF}"
else
  exec weewxd --config "${CONF}"
fi
