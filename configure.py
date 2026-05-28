#!/usr/bin/env python3
"""Patch a freshly-created WeeWX install for the docker-compose MQTT stack.

Run inside the weewx container (configobj is already available there):

    docker compose run --rm --entrypoint python weewx /configure.py

It edits, in place:

  /data/weewx.conf
    * Station metadata (Sailing Center) + a faster archive interval for the demo
    * [Station]              primary driver = weewx-mqtt/subscribe (rtl_433 via OMG)
    * [MQTTSubscribeDriver]  rtl_433 -> WeeWX field map, built from sensors.yaml
    * [MQTTPublish]          weewx-mqtt/publish -> loop packets as JSON to weather/loop
    * [Engine][Services]     publish stays RESTful; subscribe service is removed
    * [StdReport]            generate only fuzzy-archer (Bootstrap) into public_html

  /data/skins/Bootstrap/skin.conf
    * point the browser-side live gauges/charts at the broker's websocket listener

Sensor mappings live in sensors.yaml (mounted at /sensors.yaml).
Env overrides: WEEWX_DRIVER (mqtt | simulator), WEEWX_WS_URL (ws://localhost:9001),
MQTT_BROKER (mqtt), MQTT_PORT (1883), SENSORS_YAML (/sensors.yaml).
"""
import os
import sys
import configobj
import yaml
import weewx.units

CONF = "/data/weewx.conf"
SKIN = "/data/skins/Bootstrap/skin.conf"
SENSORS_YAML = os.environ.get("SENSORS_YAML", "/sensors.yaml")
WS_URL = os.environ.get("WEEWX_WS_URL", "ws://localhost:9001")
BROKER = os.environ.get("MQTT_BROKER", "mqtt")
PORT = os.environ.get("MQTT_PORT", "1883")
# MQTT credentials (from setup.sh via .env). When unset, the broker is treated
# as anonymous and no username/password is written (keeps configure.py usable
# against an unauthenticated broker).
MQTT_WEEWX_USER = os.environ.get("MQTT_WEEWX_USER", "")
MQTT_WEEWX_PASS = os.environ.get("MQTT_WEEWX_PASS", "")
MQTT_DASH_USER = os.environ.get("MQTT_DASH_USER", "")
MQTT_DASH_PASS = os.environ.get("MQTT_DASH_PASS", "")
# Driver: the base template uses the MQTTSubscribe driver (consumes a real OMG,
# or the e2e-test.sh injector). The demo layer sets WEEWX_DRIVER=simulator to run
# WeeWX's built-in Simulator instead -- full synthetic obs, no MQTT data source.
USE_SIMULATOR = os.environ.get("WEEWX_DRIVER", "mqtt").strip().lower() in ("simulator", "sim")
# Station identity -- override via the environment (.env); defaults describe the
# Sailing Center, so a reuser sets their own site without editing this file.
STATION_LOCATION = os.environ.get("STATION_LOCATION", "Sailing Center")
STATION_LATITUDE = os.environ.get("STATION_LATITUDE", "37.808")
STATION_LONGITUDE = os.environ.get("STATION_LONGITUDE", "-122.409")
STATION_ALTITUDE = os.environ.get("STATION_ALTITUDE", "3, foot")  # "value, unit"


def build_subscribe_topics(yaml_path):
    """Translate sensors.yaml into the [MQTTSubscribeDriver][[topics]] structure.

    Returns a dict ready to assign to configobj. Validates each field's
    units/name against WeeWX (the same check MQTTSubscribe makes at runtime) so
    typos fail here with a clear message instead of silently dropping data.
    """
    with open(yaml_path) as handle:
        cfg = yaml.safe_load(handle) or {}

    topics = {"unit_system": str(cfg.get("unit_system", "US"))}
    errors = []

    for sensor in cfg.get("sensors", []) or []:
        name = sensor.get("name", "?")
        topic = sensor.get("topic")
        if not topic:
            errors.append(f"sensor '{name}': missing 'topic'")
            continue
        # Default ON: rtl_433 payloads always carry string metadata (model, mic,
        # protocol, ...) that can't be floatified and would otherwise make
        # MQTTSubscribe reject the whole message. Set ignore_unmapped: false to
        # process every field instead.
        opt_out = bool(sensor.get("ignore_unmapped", True))

        section = {"message": {"type": "json"}}
        if opt_out:
            section["ignore"] = "true"
        if sensor.get("msg_id_field"):
            section["msg_id_field"] = str(sensor["msg_id_field"])

        for field, spec in (sensor.get("fields") or {}).items():
            spec = spec or {}
            entry = {}
            if opt_out:
                entry["ignore"] = "false"          # opt this field back in
            wx_name = spec.get("name", field)
            entry["name"] = wx_name
            if "units" in spec:
                units = spec["units"]
                if units not in weewx.units.conversionDict:
                    errors.append(f"sensor '{name}', field '{field}': unknown units '{units}'")
                elif wx_name not in weewx.units.obs_group_dict:
                    errors.append(f"sensor '{name}', field '{field}': '{wx_name}' "
                                  "is not a known WeeWX observation (can't apply units)")
                else:
                    entry["units"] = units
            if spec.get("contains_total"):
                entry["contains_total"] = "true"
            section[field] = entry

        topics[topic] = section

    if errors:
        sys.exit("sensors.yaml errors:\n  - " + "\n  - ".join(errors))
    return topics


def ensure_in_list(section, key, value):
    """Make sure `value` is present in a configobj list-or-scalar option."""
    cur = section.get(key, [])
    if isinstance(cur, str):
        cur = [cur] if cur else []
    else:
        cur = list(cur)
    if value not in cur:
        cur.append(value)
    section[key] = cur


def remove_from_list(section, key, value):
    """Remove `value` from a configobj list-or-scalar option, if present."""
    cur = section.get(key, [])
    if isinstance(cur, str):
        cur = [cur] if cur else []
    else:
        cur = list(cur)
    section[key] = [v for v in cur if v != value]


# ---------------------------------------------------------------- weewx.conf
c = configobj.ConfigObj(CONF, file_error=True)

# Station metadata (a coastal sailing center).
st = c.setdefault("Station", {})
st["location"] = STATION_LOCATION
st["latitude"] = STATION_LATITUDE
st["longitude"] = STATION_LONGITUDE
# Written as `3, foot` (value, unit) -- a configobj list, not a quoted string.
st["altitude"] = [p.strip() for p in STATION_ALTITUDE.split(",")]
# Primary station = weewx-mqtt/subscribe in DRIVER mode (rtl_433 data relayed by
# OpenMQTTGateway). The demo layer overrides this with the built-in Simulator.
st["station_type"] = "Simulator" if USE_SIMULATOR else "MQTTSubscribeDriver"

arc = c.setdefault("StdArchive", {})
arc["archive_interval"] = "60"        # 60 s by choice (sensors transmit every ~9-16 s)
arc["record_generation"] = "software"  # the MQTT driver has no hardware archive records

# weewx-mqtt / publish: stream every loop packet as JSON to weather/loop.
# With append_unit_label=true and US units the JSON keys (outTemp_F,
# barometer_inHg, windSpeed_mph, ...) match the fuzzy-archer gauge payload_keys.
c["MQTTPublish"] = {
    "enable": "true",
    "log_mqtt": "false",
    "host": BROKER,
    "port": PORT,
    "protocol": "MQTTv311",
    "topics": {
        "weather/loop": {
            "publish": "true",
            "type": "json",
            "binding": "loop",
            "unit_system": "US",
            "append_unit_label": "true",
        },
    },
}

# weewx-mqtt / subscribe: run as the DRIVER, configured entirely from
# sensors.yaml. Each rtl_433 JSON message from OpenMQTTGateway becomes a loop
# packet; per-field `units` declare the metric input and MQTTSubscribe converts
# to the topics' unit_system (US), so the rest of the US pipeline is unchanged.
c["MQTTSubscribeDriver"] = {
    "driver": "user.mqttsubscribe",
    "host": BROKER,
    "port": PORT,
    "topics": build_subscribe_topics(SENSORS_YAML),
}
# Not running the service variant anymore.
c.pop("MQTTSubscribeService", None)

# The WeeWX account authenticates both the subscribe driver and publish.
if MQTT_WEEWX_PASS:
    for section in ("MQTTSubscribeDriver", "MQTTPublish"):
        c[section]["username"] = MQTT_WEEWX_USER
        c[section]["password"] = MQTT_WEEWX_PASS

# Engine services: publish stays a RESTful service; the subscribe *service* must
# NOT run (we use it as the driver), so strip the entry its installer added.
svc = c.setdefault("Engine", {}).setdefault("Services", {})
remove_from_list(svc, "data_services", "user.mqttsubscribe.MQTTSubscribeService")
ensure_in_list(svc, "restful_services", "user.mqttpublish.PublishWeeWX")

# StdQC range checks: reject out-of-range / spoofed values (and inf/nan) at the
# engine. rtl_433 / 433 MHz sensors are unauthenticated, so anything within RF
# range can inject readings; bounds are the practical mitigation. weectl already
# ships defaults for outTemp/outHumidity/windSpeed/rain/barometer/etc.; add the
# rest of this stack's observations. Tune the ranges to your climate.
# Values are configobj lists (min, max, [unit]) so they're written unquoted like
# the weectl defaults -- a quoted string would be mis-parsed by StdQC.
qc = c.setdefault("StdQC", {}).setdefault("MinMax", {})
qc["windGust"] = ["0", "120", "mile_per_hour"]
qc["windDir"] = ["0", "360", "degree_compass"]
qc["UV"] = ["0", "20"]
qc["extraTemp1"] = ["-40", "120", "degree_F"]     # WH31B (adjust if used indoors)
qc["extraHumid1"] = ["0", "100"]

# Reports: generate only the fuzzy-archer (Bootstrap) skin, straight into public_html.
rep = c.setdefault("StdReport", {})
rep["HTML_ROOT"] = "public_html"
for name, sec in list(rep.items()):
    if isinstance(sec, dict) and sec.get("skin") in ("Seasons", "Standard"):
        sec["enable"] = "false"
boot = rep.setdefault("Bootstrap", {})
boot["skin"] = "Bootstrap"
boot["enable"] = "true"
boot["lang"] = "en"
boot["HTML_ROOT"] = "public_html"

c.write()
print("Patched", CONF, "(station_type =", st["station_type"] + ")")

# ----------------------------------------------------------------- skin.conf
s = configobj.ConfigObj(SKIN, file_error=True)
jg = s.setdefault("JSONGenerator", {})
jg["enabled"] = "true"
conns = jg.setdefault("MQTT", {}).setdefault("connections", {})
conns.clear()
conns["local_broker"] = {
    "broker_connection": WS_URL,
    "topics": {
        "weather/loop": {"type": "JSON"},
    },
}
# Read-only dashboard account. NOTE: these creds are embedded in the public
# weewxData.json, so the account must stay read-only and scoped (see acl).
if MQTT_DASH_PASS:
    conns["local_broker"]["mqtt_username"] = MQTT_DASH_USER
    conns["local_broker"]["mqtt_password"] = MQTT_DASH_PASS
s.write()
print("Patched", SKIN, "-> broker", WS_URL)

# ----------------------------------------------------- fuzzy-archer bug fixes
# Two in-place patches to the installed jsonengine.py (indentation preserved):
#
#  1. convert() is called with a bare string instead of a ValueTuple, which
#     raises "string index out of range" and kills the JSONGenerator whenever
#     Station altitude is in 'foot'.
#  2. On an empty archive database (fresh start, before the first archive
#     record) lastGoodStamp is None, so `lastGoodStamp - 1` raises TypeError and
#     the generator crashes. The Cheetah generator skips gracefully in this case
#     ("cannot find start time"); make JSONGenerator do the same.
JSONENGINE = "/data/bin/user/jsonengine.py"
_patches = [
    (
        "altitude convert bug",
        "altitude_m = convert(altitude[0], 'meter')[0]",
        "altitude_m = convert((float(altitude[0]), 'foot', 'group_altitude'), 'meter')[0]",
    ),
    (
        "empty-database guard",
        "            if enabled:\n                self.setup()\n                self.gen_data()",
        "            if enabled:\n"
        "                if self.db_binder.get_manager().lastGoodStamp() is None:\n"
        "                    log.info('JSONGenerator: empty archive database, skipping until data arrives')\n"
        "                    return\n"
        "                self.setup()\n"
        "                self.gen_data()",
    ),
]
with open(JSONENGINE) as f:
    _src = f.read()
for _label, _old, _new in _patches:
    if _new in _src:
        continue                       # already patched
    if _old in _src:
        _src = _src.replace(_old, _new)
        print("Patched", JSONENGINE, f"({_label})")
    else:
        # Upstream changed the line we target -> patch silently wouldn't apply
        # and the bug would return. Warn loudly so a maintainer notices.
        print(f"WARNING: {JSONENGINE} ({_label}): patch target not found; "
              "fuzzy-archer may have changed upstream -- review configure.py.",
              file=sys.stderr)
with open(JSONENGINE, "w") as f:
    f.write(_src)
