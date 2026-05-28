# WeeWX + MQTT + fuzzy-archer (Docker Compose)

A self-contained [WeeWX](https://weewx.com) weather-station stack whose primary
station is **rtl_433 sensor data relayed over MQTT by
[OpenMQTTGateway](https://docs.openmqttgateway.com/)** (OMG). WeeWX consumes it
via MQTT, re-publishes loop data to MQTT, and renders a live dashboard with the
[fuzzy-archer](https://github.com/brewster76/fuzzy-archer) (Bootstrap) skin.

Components:

| Service       | Image / source                                   | Role |
|---------------|--------------------------------------------------|------|
| `mqtt`        | `eclipse-mosquitto:2.0.22`                       | MQTT broker — TCP **1883** + WebSockets **9001** |
| `weewx`       | local image (`weewx/Dockerfile`, weewx **5.3.1**) | WeeWX engine (MQTTSubscribe **driver**) + both MQTT extensions + the skin |
| `web`         | `caddy:2.11.3-alpine`                            | Serves the report (plain HTTP **8080** in dev; TLS **443** + `wss` in prod) |
| `mqtt-ui`     | `emqx/mqttx-web:v1.13.0`                         | Browser MQTT client (**opt-in** `tools` profile) on **8083** |

The base stack is a **template** (point it at a real OMG). Layers on top: a
**demo** (`docker-compose.demo.yml`, WeeWX Simulator driver — instant synthetic
data), **production** (`docker-compose.prod.yml`, Caddy + TLS), and an end-to-end
pipeline test (`./e2e-test.sh`). See [Quick start](#quick-start).

Everything customizable about this deployment — station identity, sensors, QC bounds, units, labels, dashboard layout, branding — lives in a single [`station.yaml`](station.yaml). See [Customization](#customization-stationyaml).

WeeWX extensions (from the [`weewx-mqtt`](https://github.com/weewx-mqtt) org):

- **subscribe** ([`weewx-mqtt/subscribe`](https://github.com/weewx-mqtt/subscribe)) — runs as the **driver**, turning rtl_433 JSON into WeeWX loop packets.
- **publish** ([`weewx-mqtt/publish`](https://github.com/weewx-mqtt/publish)) — publishes loop packets as JSON to `weather/loop`.

## Data flow

```
   OMG / rtl_433 (real device, or ./e2e-test.sh)
        │  home/<omg>/RTL_433toMQTT/Fineoffset-WS80/<id>  (metric JSON:
        │  temperature_C, humidity, wind_avg_m_s, wind_dir_deg, uvi, [rain_mm])
        ▼ (subscribe, DRIVER — maps fields + converts units to US)
   [MQTTSubscribe driver] ──► loop packet (outTemp, windSpeed, … in US)
                                          │ (publish, binding=loop)
                                          ▼
                                   weather/loop (JSON: outTemp_F, windSpeed_mph,
                                          │            windGust_mph, windDir, UV, …)
                       ┌──────────────────┴───────────────────┐
                       ▼ (TCP 1883)                            ▼ (WebSocket 9001)
              archived + reports                      browser: MQTT.js live gauges
              (Caddy :8080)  ◄── fuzzy-archer ────────────────┘
```

The publish extension runs with `append_unit_label = true` and US units, so the
JSON keys (`outTemp_F`, `windSpeed_mph`, `windGust_mph`, `windDir`,
`outHumidity`, …) line up exactly with the fuzzy-archer gauge and chart
`payload_key`s — no mapping layer needed. (A WS80 has no rain or pressure, so
`barometer`/`rain` gauges stay empty; a WS90 adds `rain`.)

## Quick start

```bash
./setup.sh
```

This brings up the **base template**: WeeWX on the MQTTSubscribe driver, the
broker (with auth), and the dashboard — ready to point at a real OpenMQTTGateway.
`setup.sh` builds the image, generates the MQTT credentials into `.env`, and the
container seeds `./data` + applies `configure.py` on first run (the WeeWX install
— station + the three extensions — is baked into the image).

The template has **no data source**, so the dashboard at
**http://localhost:8080/** stays empty until data arrives — connect a device, or
use a layer below.

### Layers

The base stack is a template; demo and production sit on top as overlays:

| Goal | How |
|------|-----|
| **See it live now** (synthetic data, every gauge populated) | `docker compose down && rm -rf data mosquitto/data`<br>`COMPOSE_FILE=docker-compose.yml:docker-compose.demo.yml ./setup.sh` |
| **Test the real MQTT pipeline** end-to-end | `./e2e-test.sh` (run against the template) |
| **Health-check** whatever's running | `./verify.sh` |
| **Production** (Caddy + Let's Encrypt TLS) | [Production deployment](#production-deployment) |

The **demo** layer swaps in WeeWX's built-in Simulator driver — a full set of
synthetic observations (temperature, barometer, wind, rain) with no MQTT/RF
source, so every gauge populates. The **e2e test** is the opposite: it injects
real rtl_433-shaped JSON through the actual driver + `station.yaml` mapping +
publish path (exactly what the Simulator bypasses). The driver is chosen at
first-run bootstrap, so switch layers on a fresh `./data`.

`setup.sh` is idempotent — credentials are reused from `.env`, and the container
skips its first-run bootstrap once `data/weewx.conf` exists. To start completely
fresh:

```bash
docker compose down
rm -rf data mosquitto/data
./setup.sh
```

> **Keep `.env` and `./data` in sync.** The MQTT passwords in `.env` are baked
> into `data/weewx.conf` at first run. If you delete `.env` but keep `./data`,
> `setup.sh` generates *new* passwords and rebuilds `mosquitto/passwd`, but the
> existing `weewx.conf` still holds the old ones — WeeWX then fails to
> authenticate. Delete both together, or neither.

## What `setup.sh` does

1. Generates the three MQTT account passwords into the gitignored `.env` and
   builds the Mosquitto password file from them.
2. Builds the WeeWX image from `weewx/Dockerfile` (`weewx==5.3.1` with
   `paho-mqtt`, `ephem`, `pyyaml`, **plus the station and the three pinned
   extensions baked in**). Pin a different release with `WEEWX_VERSION=...
   ./setup.sh`.
3. Creates `./data` owned by uid 1000 (the container's `weewx` user).
4. `docker compose up`. On first start the `weewx` container seeds `./data` from
   the baked station template and runs `configure.py` to wire everything
   together (see below); thereafter it just runs `weewxd`.
5. In the demo layer it waits for the first report; the bare template has no data
   source, so it prints next-steps instead (connect an OMG / demo / e2e).

### Downloads happen at image build

The image build reaches PyPI (WeeWX + Python deps) and GitHub (the three pinned
extension archives); the running stack downloads nothing. **Behind an HTTP
proxy?** That's a Docker host setting, not a repo one: add a `"proxies"` block to
`~/.docker/config.json` and Docker injects it into the image build automatically.
The repo carries no proxy configuration.

> Why a local image instead of a published one? The popular `felddy/weewx` image
> trails the current WeeWX release by ~2 minor versions, and there's no official
> image. A ~15-line Dockerfile (`pip install weewx`) lets us pin the latest and
> drop the runtime dependency install entirely.

## What `configure.py` changes

Run inside the container (`docker compose run --rm --entrypoint python weewx /configure.py`):

- **Station** — location/lat/lon/altitude (from `station.yaml`'s `station:`
  block; defaults describe a coastal "Sailing Center"), `station_type =
  MQTTSubscribeDriver`, software record generation, and a 60-second archive
  interval (the WS80/WS90 transmit every ~9–16 s).
- **`[MQTTSubscribeDriver]`** — the **primary driver**, built from
  `station.yaml`'s `sensors:` block (see [Customization](#customization-stationyaml)).
  Each rtl_433 field maps to a WeeWX observation with per-field input `units`
  (rtl_433 is metric; the topic `unit_system` is US, so MQTTSubscribe converts).
- **`[MQTTPublish]`** — `enable=true`, `host=mqtt`, topic `weather/loop`
  (`type=json`, `binding=loop`, `unit_system=US`).
- **`[Engine][Services]`** — keeps `publish` (RESTful); removes the subscribe
  *service* entry (it's the driver now, not a service).
- **`[StdReport]`** — disables the default Seasons report; generates only
  fuzzy-archer (Bootstrap) into `public_html`.
- **`skin.conf`** — points the browser-side live gauges/charts at
  `ws://localhost:9001`, topic `weather/loop`.
- **Bug fix** — patches a fuzzy-archer `jsonengine.py` crash (`convert()` is
  called with a bare string instead of a `ValueTuple`, which otherwise kills the
  JSONGenerator whenever the altitude unit is `foot`).

## Verifying it works

Two scripts, both pass/fail and CI-friendly (non-zero exit on failure):

```bash
./verify.sh     # health of whatever's running (services, driver, errors, dashboard)
./e2e-test.sh   # active pipeline test: inject rtl_433 JSON, assert it reaches weather/loop
```

`verify.sh` adapts to the running mode — in the demo it requires live data and a
200; for the bare template (no data source) those are informational. `e2e-test.sh`
runs against the template and is the authoritative check that the real
OMG→driver→publish path works (it publishes a few synthetic readings, so run it
before connecting production data).

To inspect things by hand: the broker requires authentication (see
[Accounts & security](#accounts--security)), so load the generated credentials
first:

```bash
set -a; . ./.env; set +a

# Watch the WeeWX-processed loop packets (US units, gauge-ready keys)
docker compose exec mqtt mosquitto_sub -u "$MQTT_DASH_USER" -P "$MQTT_DASH_PASS" -t 'weather/loop' -v

# Watch raw OMG / rtl_433 messages (everything OMG publishes, exactly as it
# arrives -- the most useful view for discovering a new sensor or debugging
# field mappings in station.yaml). Tee to a file to keep them:
#   ... -t 'home/#' -v | tee /tmp/omg.log
docker compose exec mqtt mosquitto_sub -u "$MQTT_WEEWX_USER" -P "$MQTT_WEEWX_PASS" -t 'home/#' -v

# Engine logs
docker compose logs -f weewx
```

`weather/loop` alternates one sensor per message (driver behaviour — each MQTT
message is its own loop packet): WS80 packets carry `outTemp_F`, `windSpeed_mph`,
`windGust_mph`, `windDir`, `UV` (metric → US, e.g. `temperature_C: 17.4` →
`outTemp_F: 63.32`); WH31B packets carry `extraTemp1_F`, `extraHumid1`. WeeWX's
accumulator merges them into a single archive record. `barometer`/`rain` are
absent for a WS80; the WS90 adds `rain_in` (a per-interval delta of cumulative
`rain_mm`).

## MQTT client UI (opt-in)

A browser MQTT client (MQTTX Web) is available but **not started by default** —
it's a publish-capable dev tool, so it's gated behind a `tools` profile and bound
to localhost:

```bash
docker compose --profile tools up -d mqtt-ui   # then http://localhost:8083
```

Create a connection: Host `localhost`, Port `9001`, Protocol `ws`, Path `/`, and
log in with an account from `.env` (use `weewx` to also read `home/#`, or
`dashboard` for read-only `weather/loop`). It talks to the broker's WebSocket
listener — the same `ws://localhost:9001` the dashboard uses.

## Accounts & security

The broker requires authentication by default (`allow_anonymous false`). `setup.sh`
generates three least-privilege accounts on first run, stores their passwords in
the gitignored `.env`, and builds the hashed `mosquitto/passwd`. ACLs are in
[`mosquitto/acl`](mosquitto/acl):

| Account | Used by | Permission |
|---|---|---|
| `omg` | the real OMG device (+ `e2e-test.sh`) | publish-only to `home/#` |
| `weewx` | the engine (subscribe driver + publish) | read `home/#`, write `weather/#` |
| `dashboard` | the browser/skin | **read-only** `weather/loop` |
| `health` | the mqtt service's Docker healthcheck (internal only) | **read-only** `$SYS/broker/uptime` |

The `dashboard` credentials are embedded in the public `weewxData.json`, which is
why that account is read-only and scoped. Ports bind to `127.0.0.1` by default;
the broker is **plaintext** (TLS is added by the production profile — see below).

> ⚠️ **Do not expose the base stack to the internet — use the production
> profile** ([Production deployment](#production-deployment)). Plaintext MQTT
> means credentials and data are sniffable on the wire; the prod profile
> (Caddy + Let's Encrypt) adds TLS for the dashboard/`wss` and the OMG MQTT path.

You'll see a Mosquitto warning that `passwd`/`acl` are "world readable" — benign
on the pinned version (the files are gitignored / contain no plaintext secrets);
tightening their ownership conflicts with re-running `setup.sh`, so it's left as a
warning rather than enforced.

**Spoofed sensor data.** 433 MHz / rtl_433 is unauthenticated, so anything within
RF range (relayed by OMG) — or any broker client holding the `omg`/`weewx` creds —
can inject readings; broker auth can't prevent the RF path. As a mitigation,
`configure.py` configures WeeWX `StdQC` range checks (`[StdQC][[MinMax]]`) that
drop out-of-range and `inf`/`nan` values at the engine (e.g. a spoofed
`extraTemp1` of 392 °F is rejected with a `weewx.qc` warning). Tune the ranges in
`configure.py` to your climate.

## Production deployment

The base stack is plaintext and bound to localhost. The production overlay
(`docker-compose.prod.yml`) reconfigures the **`web` (Caddy)** service for
automatic Let's Encrypt — HTTPS for the dashboard, `wss` for live data — and adds
a **TLS MQTT listener on 8883** for OpenMQTTGateway. **Prerequisites:** a public
DNS name pointing at the host, with ports **80, 443, 8883** reachable (80 is
required for the ACME challenge).

```bash
set -a; . ./.env; set +a          # load the generated MQTT creds
```

1. **Set the domain** in `.env`:
   ```
   DOMAIN=weather.example.com
   ACME_EMAIL=you@example.com
   ```
2. **Re-point the dashboard's live data at `wss`** (the browser now reaches the
   broker through Caddy, not `localhost:9001`). This rewrites `weewx.conf`, so
   pass all the accounts:
   ```bash
   docker compose run --rm --entrypoint python \
     -e WEEWX_WS_URL="wss://$DOMAIN" \
     -e MQTT_WEEWX_USER -e MQTT_WEEWX_PASS -e MQTT_DASH_USER -e MQTT_DASH_PASS \
     weewx /configure.py
   docker compose restart weewx
   ```
3. **Create a bootstrap MQTT cert** so the 8883 listener can start before Caddy
   issues the real one (the sidecar swaps it in within ~30 s):
   ```bash
   mkdir -p mosquitto/certs
   openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
     -keyout mosquitto/certs/mqtt.key -out mosquitto/certs/mqtt.crt -subj "/CN=$DOMAIN"
   ```
4. **Bring up the overlay** (the base template has no data source — a real OMG
   provides it):
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
   ```
5. **Point OMG** at `mqtts://$DOMAIN:8883` with the `omg` account from `.env`.

Dashboard → `https://$DOMAIN`. How the TLS is wired:
- The `web` service (Caddy) obtains/renews Let's Encrypt certs, serves the report
  over HTTPS directly from `/srv`, and routes `Connection: Upgrade` requests to
  `mqtt:9001`, giving the browser `wss`.
- Mosquitto serves `8883` itself (raw MQTT isn't HTTP, so it can't go through
  Caddy). The `cert-reload` sidecar copies Caddy's renewed cert to Mosquitto and
  sends `SIGHUP`, which hot-reloads the cert (verified — zero downtime). It
  signals Mosquitto through a shared PID namespace, so **no Docker socket** is
  mounted.

**Encryption posture.** Everything internet-facing is TLS: Caddy `443`
(dashboard https + `wss`) and Mosquitto `8883` (MQTTS for OMG). Port `80` is only
Caddy's ACME challenge + HTTP→HTTPS redirect. In the prod overlay the plaintext
listeners `1883`/`9001` are forced back to `127.0.0.1` via `ports: !override`
(the base file binds `1883` to `0.0.0.0` for LAN-OMG convenience; prod replaces
that so plaintext never leaves the prod host), and the broker rejects anonymous
clients regardless — so plaintext is not an external surface in prod.

The remaining plaintext is **container-to-container on the private Docker bridge**
(`weewx→mqtt:1883`, `Caddy→mqtt:9001`) — left unencrypted on purpose. On a single
host that hop never leaves the machine, and the Let's Encrypt cert is issued for
`$DOMAIN`, not the internal service name `mqtt`, so internal TLS would mean a
separate internal CA (or disabling hostname verification) for negligible gain. If
you split services across hosts, revisit this: put them on an encrypted overlay
network, or issue an internal cert with a `mqtt` SAN and point the clients at it.

## Configuration & customization

- **Ports** — `1883` MQTT (bound to `0.0.0.0` so a LAN OMG can publish),
  `9001` MQTT/WebSocket and `8080` web (both bound to `127.0.0.1` — remote
  browser access is the prod overlay's job, via Caddy on `443`). Change the
  `ports:` mappings in `docker-compose.yml` if you want different defaults.
- **Viewing from another machine.** The browser connects *directly* to the broker
  over WebSockets, so `localhost` won't resolve remotely. Re-point it:
  ```bash
  WEEWX_WS_URL="ws://<host-ip-or-name>:9001" \
    docker compose run --rm --entrypoint python weewx /configure.py
  docker compose restart weewx && docker compose exec weewx weectl report run --config /data/weewx.conf
  ```

## Using a real OpenMQTTGateway device

The base template already runs the MQTTSubscribe driver, so there's nothing to
"switch on" — just give it a data source. (There's no emulator service to stop;
`./e2e-test.sh` is the only synthetic publisher, and it's a one-shot test.)

1. **Point OMG at this broker** (its web UI → MQTT): host = this machine, port
   `1883` (the base profile binds it to `0.0.0.0`, so it's reachable from the
   LAN — plaintext, but the broker requires auth), and the `omg` account from
   `.env`. For an OMG on the public internet (or any untrusted network), bring
   up the [production TLS profile](#production-deployment) and use `mqtts://`
   on `8883` instead. Enable OMG's RTL_433 gateway and note its base topic
   (e.g. `home/OMG_a1b2`).
2. **Confirm the topic + fields** the device actually sends:
   `set -a; . ./.env; set +a; docker compose exec mqtt mosquitto_sub -u "$MQTT_WEEWX_USER" -P "$MQTT_WEEWX_PASS" -t 'home/#' -v`. The WS80/WS90 land on
   `home/<omg>/RTL_433toMQTT/Fineoffset-WS80|WS90/<id>`.
3. **Edit [`station.yaml`](station.yaml)** — the `sensors:` block — to match
   what you saw in step 2: set the model in the topic (e.g. `Fineoffset-WS90`)
   and add/adjust sensor entries. Re-apply with `docker compose run --rm
   --entrypoint python weewx /configure.py && docker compose restart weewx`
   (or a fresh `./setup.sh`).

Notes: a WS80 provides no rain or barometric pressure (pressure normally comes
from an Ecowitt console, not the RF sensor), so those gauges stay empty; a WS90
adds rain. rtl_433 reports metric — the per-field `units` in `station.yaml`'s
`sensors:` block handle the conversion to US.

## Customization (`station.yaml`)

[`station.yaml`](station.yaml) is the single source of configurable truth for
this deployment. `configure.py` compiles it into `weewx.conf` + `skin.conf`
(and, when set, generated `user/extra_obs.py` / `user/extra_schema.py`) at
first-run bootstrap. Secrets stay in `.env` — everything else is here.

Top-level sections:

| Section | What it drives |
|---|---|
| `station` | location, lat/lon/altitude, `archive_interval` |
| `mqtt` | broker host/port and the browser-facing WebSocket URL |
| `sensors` | rtl_433 → WeeWX field map (the `[MQTTSubscribeDriver][[topics]]` content) |
| `qc` | `[StdQC][[MinMax]]` bounds per observation (spoofing mitigation) |
| `observations` *(opt)* | new obs types — generates `user/extra_obs.py` + registers `obs_group_dict` |
| `schema` *(opt)* | extra DB columns — generates `user/extra_schema.py` extending the stock schema |
| `units` *(opt)* | force display units per group + define brand-new unit groups |
| `labels` *(opt)* | per-observation display labels (`[Labels][Generic]`) |

Re-apply after editing (the first-run bootstrap is skipped once
`data/weewx.conf` exists):

```bash
docker compose run --rm --entrypoint python weewx /configure.py && \
  docker compose restart weewx
```

The `sensors:` block follows the per-rtl_433-sensor shape:

```yaml
sensors:
  unit_system: US
  sources:
    - name: primary
      topic: home/+/RTL_433toMQTT/Fineoffset-WS80/+   # WS90 in production
      fields:
        temperature_C: { name: outTemp, units: degree_C }
        wind_avg_m_s:  { name: windSpeed, units: meter_per_second }
        rain_mm:       { name: rain, units: mm, contains_total: true }  # WS90
        # ...
    - name: wh31b-ch1
      topic: home/+/RTL_433toMQTT/AmbientWeather-WH31B/+
      msg_id_field: channel                # distinguish channels (stable across battery swaps)
      fields:
        temperature_C_1: { name: extraTemp1, units: degree_C }  # channel 1
        humidity_1:      { name: extraHumid1 }
```

Key points, each verified end-to-end:

- **Same generic keys, different targets.** Every rtl_433 sensor sends
  `temperature_C`/`humidity`, so each sensor maps them to *different* WeeWX
  observations (`outTemp` vs `extraTemp1` vs `inTemp`). Targets come from the
  `wview_extended` schema (`inTemp`, `extraTemp1..8`, `extraHumid1..8`, …).
- **Unmapped fields are dropped by default.** rtl_433 payloads carry string
  metadata (`model`, `mic`, `protocol`); without dropping them MQTTSubscribe
  fails converting `model` to a float and discards the whole message. List only
  what you want; set `ignore_unmapped: false` to keep everything.
- **`msg_id_field`** lets one wildcard topic serve a family of same-model sensors
  (e.g. several WH31B channels). The id value is appended to each field name —
  `temperature_C` on channel 1 → `temperature_C_1` — which you then map.
  (`channel` is stable across battery swaps; the `id` in the topic is not.)
- **`contains_total: true`** converts a cumulative counter (rain) to a
  per-interval delta.
- **One loop packet per message.** In driver mode each incoming message is its
  own loop packet, so `weather/loop` shows one sensor at a time; WeeWX merges
  them into a single archive record.

## Layout

```
docker-compose.yml            # base template: mqtt + weewx + web (default = localhost)
docker-compose.demo.yml       # demo overlay: WeeWX Simulator driver (synthetic data)
docker-compose.prod.yml       # prod overlay: Caddy + TLS + cert-reload
weewx/Dockerfile              # local WeeWX image (pinned release + extensions baked in)
weewx/entrypoint.sh           # first-run seed+configure / weectl-passthrough / weewxd
mosquitto/mosquitto.conf      # base broker: 1883 (mqtt) + 9001 (ws), auth + ACLs
mosquitto/mosquitto.prod.conf # adds the 8883 TLS listener (prod)
mosquitto/acl                 # per-account topic permissions (passwd is generated, gitignored)
caddy/Caddyfile               # the `web` server's dev config: plain HTTP on :8080
caddy/Caddyfile.prod          # prod config: Let's Encrypt TLS (https) + wss + file_server
cert-reload/reload.sh         # syncs Caddy's cert to mosquitto + SIGHUP (prod)
configure.py                  # compiles station.yaml into weewx.conf/skin.conf
station.yaml                  # the single source of configurable truth (edit this!)
setup.sh                      # bootstrap (gen creds, build image, start)
verify.sh                     # health check (pass/fail) of the running stack
e2e-test.sh                   # e2e pipeline test: inject rtl_433 JSON, assert weather/loop
.env.example                  # production (DOMAIN/ACME_EMAIL) settings template
data/                         # WeeWX root: weewx.conf, weewx.sdb, public_html/ (generated)
```
