# LAN Media Wall broker — Synology-friendly container.
# Build:  docker build -t lmw-broker .
# Run:    docker run -d --name lmw-broker \
#           -p 8770:8770 -p 8771:8771 -p 8772:8772/udp \
#           -e LMW_PSK=<your-32+byte-hex> \
#           -v /volume1/docker/lmw-broker:/data \
#           lmw-broker
FROM python:3.11-slim

WORKDIR /app

# Install runtime deps first for layer caching.
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir websockets PyYAML

# Application code.
COPY *.py /app/

# Persist registry + certs under /data (mount a Synology shared folder here).
ENV LMW_CONFIG=/data/config.yaml
WORKDIR /data
# state.json lives in /data; broker.py reads cfg state_path relative to CWD.

EXPOSE 8770 8771 8772/udp

# PSK must be supplied via -e LMW_PSK=... or /data/config.yaml.
CMD ["python3", "/app/broker.py"]
