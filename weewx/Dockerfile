# Minimal WeeWX image, pinned to a specific release (we build our own rather
# than use a published image to track the current WeeWX -- see the README,
# "Why a local image"). Build context is the project root; see docker-compose.yml.
FROM python:3.13.13-slim

ARG WEEWX_VERSION=5.3.1
# Pinned extensions, baked into a station template below. publish uses a
# release tag; subscribe is pinned to a master commit because the features
# this stack relies on (msg_id_field, per-field units, wildcard topic
# matching, the user.mqttsubscribe driver module) are newer than its latest
# release (v3.1.1).
#
# fuzzy-archer is TEMPORARILY pulled from a fork branch
# (claudobahn/fuzzy-archer:jsonengine-fixes) carrying five jsonengine.py
# patches submitted upstream:
#   - empty-archive guard (don't crash JSONGenerator on a fresh DB)
#   - altitude.convert ValueTuple fix (foot stations were crashing)
#   - observationType emitted on each gauge config (browser unit conversion)
#   - observationType emitted on each chart series config (same)
#   - tolerate absent [[Defaults]][[[Units]]] / [[[Labels]]] override sections
# Once any of those merge to brewster76/fuzzy-archer:master and a release
# tag is cut, flip the URL back to brewster76 and pin FUZZY_REF to that tag.
ARG PUBLISH_REF=refs/tags/v1.1.0-rc04a
ARG SUBSCRIBE_REF=72a9d1dcc1cad5c063cd04b4ef9df6d0608be7e7
ARG FUZZY_REPO=claudobahn/fuzzy-archer
ARG FUZZY_REF=refs/heads/jsonengine-fixes
ENV PIP_ROOT_USER_ACTION=ignore

# WeeWX + almanac (ephem) + the MQTT client the extensions use + pyyaml (read by
# configure.py), all baked in so the running stack never installs anything.
# No libusb: sensor data arrives over MQTT (OpenMQTTGateway does the RF decode),
# so no USB device is needed -- even with real hardware. Add libusb-1.0-0 only
# if you attach a USB-connected station driver instead.
RUN pip install --no-cache-dir "weewx==${WEEWX_VERSION}" ephem paho-mqtt pyyaml

RUN useradd --system --uid 1000 --create-home --home-dir /home/weewx weewx

# Baked station template. Built AS /data so the generated weewx.conf records
# WEEWX_ROOT=/data (correct at runtime), then moved aside to /opt/station. On
# first run the entrypoint copies it into the bind-mounted, initially-empty
# /data and applies configure.py. All extension downloads happen here at build
# time, so the running stack is self-contained and reproducible from the pinned
# refs above (bump a ref -> rebuild the image).
RUN weectl station create --no-prompt /data \
 && printf '\n[Logging]\n    [[root]]\n        level = INFO\n        handlers = console,\n' >> /data/weewx.conf \
 && weectl extension install "https://github.com/weewx-mqtt/publish/archive/${PUBLISH_REF}.zip" --yes --config /data/weewx.conf \
 && weectl extension install "https://github.com/weewx-mqtt/subscribe/archive/${SUBSCRIBE_REF}.zip" --yes --config /data/weewx.conf \
 && weectl extension install "https://github.com/${FUZZY_REPO}/archive/${FUZZY_REF}.zip" --yes --config /data/weewx.conf \
 && mv /data /opt/station \
 && mkdir -p /data \
 && python3 -c "import uuid; open('/opt/station/.image-id', 'w').write(str(uuid.uuid4()))" \
 && chown -R weewx:weewx /opt/station /data
VOLUME ["/data"]

COPY weewx/entrypoint.sh /entrypoint.sh
USER weewx
ENTRYPOINT ["/entrypoint.sh"]
