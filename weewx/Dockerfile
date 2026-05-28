# Minimal WeeWX image, pinned to a specific release (we build our own rather
# than use a published image to track the current WeeWX -- see the README,
# "Why a local image"). Build context is the project root; see docker-compose.yml.
FROM python:3.13.13-slim

ARG WEEWX_VERSION=5.3.1
# Pinned extensions, baked into a station template below. publish + fuzzy-archer
# use release tags; subscribe is pinned to a master commit because the features
# this stack relies on (msg_id_field, per-field units, wildcard topic matching,
# the user.mqttsubscribe driver module) are newer than its latest release (v3.1.1).
ARG PUBLISH_REF=refs/tags/v1.1.0-rc04a
ARG SUBSCRIBE_REF=72a9d1dcc1cad5c063cd04b4ef9df6d0608be7e7
ARG FUZZY_REF=refs/tags/v4.4
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
 && weectl extension install "https://github.com/brewster76/fuzzy-archer/archive/${FUZZY_REF}.zip" --yes --config /data/weewx.conf \
 && mv /data /opt/station \
 && mkdir -p /data \
 && chown -R weewx:weewx /opt/station /data
VOLUME ["/data"]

COPY weewx/entrypoint.sh /entrypoint.sh
USER weewx
ENTRYPOINT ["/entrypoint.sh"]
