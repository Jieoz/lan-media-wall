# LAN Media Wall — Broker

Central coordinator for the LAN media wall. Players (Windows/Android) and
controllers (Flutter) connect only to this broker over WebSocket; the broker
owns the device registry, group assignments, the master clock, status
aggregation, and command fan-out.

This implements the broker-side responsibilities of
[`../protocol_spec.md`](../protocol_spec.md) (§2–§10). That spec is the
contract — field names and semantics here follow it exactly.

## Modules

| File | Responsibility |
|---|---|
| `broker.py` | asyncio entry point + WS/WSS server, connection lifecycle, dispatch |
| `envelope.py` | envelope build/parse, HMAC sign/verify, msg_id dedup, ts window (§2/§3) |
| `registry.py` | device table, grouping, `state.json` persistence (§4/§5) |
| `router.py` | fan-out resolution by the `to` field (§2/§9.3) |
| `clock.py` | master clock + time-sync ack + NTP offset/rtt math (§8) |
| `sync.py` | three-phase prepare→ready→play_at state machine (§9) |
| `discovery.py` | optional UDP 8772 discover/announce (§7) |

## Ports

- `8770` WS (always on)
- `8771` WSS (enabled automatically when `certs/cert.pem` + `certs/key.pem` exist)
- `8772` UDP discovery (opt-in via `enable_discovery: true`)

## Configuration

The PSK (HMAC pre-shared key, §3) is required. It must be identical on every
player and controller. Provide it via the `LMW_PSK` env var (preferred) or in
`config.yaml`:

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"   # generate one
```

Copy `config.example.yaml` to `config.yaml` to tune ports, the sync buffer
(`buffer_ms`, default 1500), the ready timeout (`ready_timeout_ms`, default
2000), and throttling. Env `LMW_PSK` overrides the file.

## Run locally

```bash
pip install -r requirements.txt
LMW_PSK=$(python3 -c "import secrets; print(secrets.token_hex(32))") python3 broker.py
```

## Run on Synology (Docker)

```bash
docker build -t lmw-broker .
docker run -d --name lmw-broker \
  -p 8770:8770 -p 8771:8771 -p 8772:8772/udp \
  -e LMW_PSK=<your-32+byte-hex> \
  -v /volume1/docker/lmw-broker:/data \
  lmw-broker
```

`state.json` (and an optional `config.yaml` / `certs/`) live in the mounted
`/data` volume so registry and group assignments survive restarts. Drop
`cert.pem` + `key.pem` into `/data/certs/` to enable WSS on 8771.

In Synology's Container Manager you can equivalently create the container from
this image, map the three ports, set the `LMW_PSK` environment variable, and
mount a shared folder to `/data`.

## Tests

```bash
python3 -m pytest tests/ -q        # unit tests (envelope/clock/sync/router/registry)
python3 tests/smoke_local.py       # end-to-end: hello/welcome, status/wall,
                                    # time_sync, prepare→ready→play_at
```

## Behavior notes

- **Auth pipeline** (every frame): HMAC verify → ts window (±30s, ±120s on the
  first frame) → msg_id dedup (5-min LRU). 5 signature failures on a connection
  trip a 60s cooldown for that IP.
- **Clock** (§8): the broker's wall clock is the single master timeline.
  `time_sync_ack` echoes `t1`, stamps `t2` at receive (as early as possible) and
  `t3` at send (as late as possible). Players do the offset/rtt math.
- **Sync start** (§9): `prepare` fans out to the group; the broker collects
  `ready` from all online members (or fires after `ready_timeout_ms` for
  whoever is ready), then broadcasts `play_at = server_now + buffer_ms`. When a
  group's `sync` flag is false, the broker skips the handshake and emits
  `play_at = now` per member.
- **Wall** (§5.2): player `status` is aggregated and pushed to controllers at
  most once per `wall_interval_ms`, and only while a controller is online.
- **Thumbnails** (§6.4): a `thumb_meta` JSON frame followed by one binary frame
  is forwarded to controllers; binary frames are dropped unless a controller is
  online.
- **Robustness**: a single connection's exception is contained and never stops
  the broker; on disconnect a player is marked offline and the wall refreshed.
  `state.json` is written atomically (temp file + rename).

## Security

Without WSS, traffic is plaintext on the LAN but every control message is still
HMAC-signed and replay-protected, so commands cannot be forged or replayed.
Enable WSS (drop certs in `certs/`) for confidentiality. The broker has **no
per-device authorization beyond the shared PSK** — anyone with the PSK on the
LAN is fully trusted. Keep the PSK secret and the broker off untrusted networks.
