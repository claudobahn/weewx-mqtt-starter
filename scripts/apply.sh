#!/bin/sh
# Re-apply station.yaml to the running stack. Safe for benign edits (sensors,
# qc, dashboard, labels, units, branding, logging, services). See README's
# "Updating an existing deployment" section for the benign/destructive matrix
# and the wipe-and-restore sequence for destructive changes.
#
# Equivalent to just running `docker compose restart weewx` -- the entrypoint
# auto-detects station.yaml changes by hash and re-runs configure.py itself.
# This wrapper is the convenience entry point for the common flow and also
# exposes `--regen` to force a one-off report rebuild.
#
# Usage:
#   ./scripts/apply.sh           # apply + restart weewx (next loop refreshes HTML)
#   ./scripts/apply.sh --regen   # also force a Bootstrap report regen now
set -eu
cd "$(dirname "$0")/.."

DC="docker compose"

# Recompile station.yaml -> weewx.conf / skin.conf with a transient container
# (so the running weewx isn't restarted mid-write). configure.py refreshes
# /data/.station-yaml.hash, which the entrypoint compares on the next start.
$DC run --rm --no-deps --entrypoint python weewx /configure.py
$DC restart weewx

if [ "${1:-}" = "--regen" ]; then
  # weectl reads the system clock via Python's `time` module, which honours TZ
  # set in the process environment. The entrypoint resolved TZ from
  # station.timezone for weewxd (PID 1), but `docker compose exec` spawns a
  # fresh shell that bypasses the entrypoint -- so without forwarding TZ here,
  # weectl renders timestamps in UTC even when station.timezone is set. Pull
  # the resolved TZ from PID 1's environ (the source of truth, since the
  # entrypoint already evaluated station.yaml and exported it there) and pass
  # it explicitly to `exec`. Empty when no station.timezone is configured;
  # weectl falls back to /etc/localtime / UTC in that case.
  TZ_VALUE="$($DC exec -T weewx sh -c 'tr "\0" "\n" < /proc/1/environ | sed -n "s/^TZ=//p"' 2>/dev/null || true)"
  if [ -n "$TZ_VALUE" ]; then
    echo "Forcing a Bootstrap report regen (TZ=${TZ_VALUE})..."
    $DC exec -e "TZ=${TZ_VALUE}" weewx weectl report run Bootstrap --config /data/weewx.conf
  else
    echo "Forcing a Bootstrap report regen..."
    $DC exec weewx weectl report run Bootstrap --config /data/weewx.conf
  fi
fi

echo
echo "Applied. Reports refresh on the next archive interval; pass --regen to"
echo "force one now."
