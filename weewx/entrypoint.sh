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
  # Image-template reconciliation: /data was seeded from /opt/station on
  # first run; later image rebuilds (new fuzzy-archer/, bumped extension
  # pin, new configure.py defaults) update /opt/station but not the already-
  # seeded /data. A build-time UUID stamp in /opt/station/.image-id lets us
  # detect that mismatch and refresh skin + user-code assets in place. The
  # config and database are left alone -- weewx.conf is configure.py-owned
  # and the SDB carries all archive history. cp -a leaves files-only-in-
  # /data alone, so configure.py's generated extra_obs.py etc. survive.
  # After a refresh, invalidate the station.yaml hash so the block below
  # re-runs configure.py (a new image may bring new skin.conf defaults
  # that need station.yaml overrides re-applied on top).
  if [ -f /opt/station/.image-id ]; then
    current_image="$(cat /opt/station/.image-id)"
    applied_image="$(cat "${WEEWX_ROOT}/.image-id" 2>/dev/null || true)"
    if [ "${current_image}" != "${applied_image}" ]; then
      echo "Image template changed since last start; refreshing skins + bin/user."
      # Non-fatal: this block is best-effort. `set -e` is active, so any
      # failure here (a /data permission quirk, a read-only or full FS, an
      # FS hiccup) would otherwise abort the script -> container exits ->
      # restarts -> the stamp is still stale -> the mismatch never clears ->
      # silent crash-loop. Guard the refresh so a failure logs a WARNING and
      # falls through to weewxd on the previous /data instead. Only stamp
      # .image-id once the copies AND the hash-invalidation succeed, so a
      # partial refresh is retried next start rather than marked done.
      # Mirrors the station.yaml block's keep-calm-and-carry-on handling.
      if cp -a /opt/station/skins/. "${WEEWX_ROOT}/skins/" \
         && { [ ! -d /opt/station/bin/user ] || cp -a /opt/station/bin/user/. "${WEEWX_ROOT}/bin/user/"; } \
         && rm -f "${WEEWX_ROOT}/.station-yaml.hash" \
         && echo "${current_image}" > "${WEEWX_ROOT}/.image-id"; then
        :
      else
        echo "WARNING: image-template refresh failed; continuing on the" \
             "previous /data. Will retry on the next start." >&2
      fi
    fi
  fi

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
