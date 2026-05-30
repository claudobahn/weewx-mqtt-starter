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
  echo "Forcing a Bootstrap report regen..."
  $DC exec weewx weectl report run Bootstrap --config /data/weewx.conf
fi

echo
echo "Applied. Reports refresh on the next archive interval; pass --regen to"
echo "force one now."
