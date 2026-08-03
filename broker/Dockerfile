# LAN Media Wall broker — Synology-friendly container.
#
# 推荐用 compose(见 docker-compose.yml,已处理 host 网络与全部四个端口):
#   docker compose up -d
#
# 手动 docker run 等价写法。注意 --network host:broker 的 UDP 自动发现往
# 255.255.255.255 发广播,而广播不跨 Docker bridge 网络 —— 用 -p 映射的话
# WebSocket 能连上但自动发现会静默失效(现场表现为盒子扫不到 broker,必须手填 IP)。
#   docker run -d --name lmw-broker --network host \
#     -v /volume1/docker/lmw-broker:/data \
#     lmw-broker
#
# 若环境不能用 host 网络,退回端口映射并接受「需手填 broker IP」:
#   docker run -d --name lmw-broker \
#     -p 8770:8770 -p 8771:8771 -p 8772:8772/udp -p 8773:8773 \
#     -v /volume1/docker/lmw-broker:/data \
#     lmw-broker
#
# auth_mode 默认 open(零配置)。要签名校验时加 -e LMW_AUTH_MODE=required
# 和 -e LMW_PSK=<32+ 字节 hex>,三端必须同一个 PSK。
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

# 8773 = §20.1 媒体库上传/下载,默认开启(media_port 默认 8773),控制端的
# 本地上传走这个口。以前这里漏了它。
EXPOSE 8770 8771 8772/udp 8773

# PSK must be supplied via -e LMW_PSK=... or /data/config.yaml.
CMD ["python3", "/app/broker.py"]
