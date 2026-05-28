#!/bin/sh
# Keeps Mosquitto's 8883 TLS cert in sync with Caddy's Let's Encrypt cert.
#
# Caddy stores certs under its data dir as <domain>.crt / <domain>.key. This
# sidecar shares Mosquitto's PID namespace (pid: service:mqtt in compose), so it
# can signal mosquitto directly with SIGHUP -- no Docker socket required.
# Mosquitto reloads its certificate on SIGHUP (verified), so renewal is
# zero-downtime.
set -eu

: "${DOMAIN:?DOMAIN must be set}"
CADDY_DATA="${CADDY_DATA:-/caddy-data}"   # Caddy's /data, mounted read-only
DST="${CERT_DST:-/certs}"                 # shared with mosquitto (rw)

echo "cert-reload: watching ${CADDY_DATA} for ${DOMAIN}.crt -> ${DST}/mqtt.{crt,key} (reload via SIGHUP)"

prev=""
while :; do
  src="$(find "${CADDY_DATA}" -type f -name "${DOMAIN}.crt" 2>/dev/null | head -n1)"
  if [ -n "${src}" ] && [ -f "${src%.crt}.key" ]; then
    cur="$(sha256sum "${src}" | awk '{print $1}')"
    if [ "${cur}" != "${prev}" ]; then
      cp "${src}" "${DST}/mqtt.crt"
      cp "${src%.crt}.key" "${DST}/mqtt.key"
      echo "cert-reload: installed Caddy cert for ${DOMAIN}; signalling mosquitto (SIGHUP)"
      kill -HUP 1 2>/dev/null || \
        echo "cert-reload: WARNING - could not signal mosquitto (needs 'pid: service:mqtt')"
      prev="${cur}"
    fi
  fi
  sleep 30
done
