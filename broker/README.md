# LAN Media Wall — Broker

Central coordinator for the LAN media wall. Players (Windows/Android) and
controllers (Flutter) connect only to this broker over WebSocket; the broker
owns the device registry, group assignments, the master clock, status
aggregation, and command fan-out.

This implements the broker-side responsibilities of
[`../protocol_spec.md`](../protocol_spec.md) (§2–§10, plus the v1.2 additions
§13–§15, the v1.3 derived keys §17, and the v1.4 group CRUD §18 / device config
§19 / media library §20 / prefetch barrier §21). That spec is the contract —
field names and semantics here follow it exactly.

## Modules

| File | Responsibility |
|---|---|
| `broker.py` | asyncio entry point + WS/WSS server, connection lifecycle, dispatch, auth-mode gating; §18 group CRUD + §19 configure_device dispatch; §21 prefetch-barrier timeout |
| `envelope.py` | envelope build/parse, HMAC sign/verify, auth-mode + derived-key helpers, msg_id dedup, ts window (§2/§3/§13/§17) |
| `registry.py` | device table, explicit group create/update/delete + assignment, `state.json` persistence (§4/§5/§18/§19) |
| `media_server.py` | **v1.4** broker media library over HTTP (stdlib asyncio, no deps): `PUT/GET /media/<sha256>` with sha256-guarded upload, dedup, and Range resumable download (§20.1) |
| `router.py` | fan-out resolution by the `to` field (§2/§9.3) |
| `clock.py` | master clock + time-sync ack + NTP offset/rtt math (§8) |
| `sync.py` | three-phase prepare→ready→play_at state machine, with the §21 long prefetch-barrier timeout (§9/§21) |
| `discovery.py` | UDP 8772 discover/announce, self-announce + discover replies (§7/§14.5) |
| `pairing.py` | `lmw://pair?...` URI builder + terminal QR; derived per-endpoint codes (§15/§17.4) |

## v1.13.4 — remote logs + debug snapshot forwarding

The broker dispatch table explicitly routes the single-device diagnostics added
in §24 of the protocol spec:

- controller→player requests: `download_logs`, `debug_snapshot`, routed by the
  normal `to`/`target` device selection and broadcast only to player clients.
- player→controller replies: `download_logs_result`, `diagnostic_status`,
  accepted only from `role == "player"` and broadcast to connected controllers.

This is a required hop, not an optimization. If these four message types are
missing from broker routing, the controller button will time out even though both
endpoints compile. `broker/tests/test_debug_routing.py` guards the request and
reply directions.

## Ports

- `8770` WS (always on)
- `8771` WSS (enabled automatically when `certs/cert.pem` + `certs/key.pem` exist)
- `8772` UDP discovery (on by default; `enable_discovery: false` to disable)
- `8773` HTTP media library (v1.4; `media_port`, on when a cache dir is configured — see below)

## v1.4 — group CRUD, device config, media library, prefetch barrier (§18–§21)

- **Explicit group management (§18)**: beyond `assign_group`, the broker handles
  `create_group` / `update_group` / `delete_group` from controllers, persisted in
  `state.json`. Deleting a group reassigns its members to `default` rather than
  orphaning them.
- **Device configuration (§19)**: `configure_device` sets a player's display
  name / group / volume in one message, targeted by `device_id`; the broker
  applies registry-side effects and forwards it to the player, which persists the
  change locally.
- **Media library (§20.1)**: `media_server.py` serves a content-addressed store
  at `/media/<sha256>`. Controllers `PUT` a local file (mode B upload); the
  broker verifies the body's sha256 against the URL, dedups identical content,
  and serves `GET` with HTTP Range so players resume interrupted downloads.
  Downloads stay open for players; uploads can require `media_upload_token`, and
  `media_bind_host` can bind the endpoint to loopback behind a reverse proxy.
  Pure stdlib asyncio — no extra dependency, safe for the Synology Docker target.
- **Prefetch barrier (§21)**: for a synced start the controller may send
  `prepare(prefetch:true)`; the broker widens the `ready` collection timeout
  (barrier timeout, default 120s) so every member finishes downloading +
  verifying before `play_at`, instead of firing at the short 2s `ready_timeout_ms`.

## v1.2 — auth modes, topology, pairing (§13–§15)

### Auth modes (§13)

`auth_mode` (config / `LMW_AUTH_MODE` env / `config.yaml`) picks how strictly
the HMAC from §3 is enforced:

| mode | broker verifies inbound | broker signs outbound | PSK needed | cooldown |
|---|---|---|---|---|
| `open` (**default**) | never | no (`sig:""`) | no | no |
| `optional` | only when `sig` non-empty | when a PSK is set | no | no |
| `required` | always (strict) | always | **yes** | yes |

The ts-window (±30s/±120s) and msg_id dedup run in **every** mode — replay
hygiene needs no key. The auth-fail counter + 60s cooldown apply **only** in
`required`. The active mode is advertised in `welcome.payload.auth_mode` and the
UDP `announce.payload.auth_mode`, so endpoints self-adapt. `open` is fully
zero-config: no PSK, no flags.

### Topology (§14)

`topology` (config / `LMW_TOPOLOGY`) is advertised in `welcome` + `announce`:

- `dedicated` (default) — standalone broker process/container.
- `cohosted` — the same broker embedded in a player process. Import and launch
  it in-process with `await broker.run_broker(cfg)` (or pass a `ready_event` to
  wait until it is listening, then connect the local player to `127.0.0.1:8770`).
  Wire behavior is identical to dedicated; only the advertised `topology`
  differs. `p2p` is not a broker mode — it has no broker.

The broker self-announces over UDP (`announce_interval_ms`, default 5s) carrying
`topology`, `auth_mode`, and `broker_hint` (`host:port`), and unicasts an
`announce` in reply to any `discover` packet, so endpoints auto-find it (§14.5).

### Pairing (§15)

On startup the broker prints an `lmw://pair?...` URI (and a scannable terminal
QR when the optional `qrcode` package is installed; otherwise the URI plus a
note). Scan it to onboard an endpoint with no hand-typing. In `open` mode the
URI carries **no** key. In `optional`/`required` what it carries depends on
`key_mode` (below): `global` embeds the PSK; `derived` embeds that endpoint's
own `dk` (device_key hex) + `id` and **never** the PSK. See `pairing.py`
(`build_pairing_uri` / `pairing_uri_from_config` / `device_pairing_uri`).

### Derived keys (§17, v1.3)

`key_mode` (config / `LMW_KEY_MODE`) chooses the HMAC key used when signing is
active (`auth_mode` `optional`/`required`); it is moot under `open`.

| key_mode | HMAC key | use |
|---|---|---|
| `derived` (default) | per-endpoint `device_key = HMAC_SHA256(PSK, identity)` | leak isolation — a stolen player key forges only that player |
| `global` | the raw PSK (v1.2 behaviour) | interop with endpoints not yet upgraded to v1.3 |

`identity` is the envelope `from` string verbatim (`player:<id>`,
`controller:<id>`, or `broker`) — no normalization. The broker holds only the
**one** PSK and derives each endpoint's key on the fly (stateless), so verifying
a frame derives the key from that frame's own `from`: a frame signed for
identity-A but claiming `from=B` fails. Deployment is unchanged from v1.2 — you
still configure a single PSK; endpoints receive only their own `device_key` via
the pairing QR and never touch the PSK. `key_mode` is advertised in
`welcome.payload.key_mode` and the UDP `announce.payload.key_mode`; a missing
field is read as `global` (backward compat).

## Configuration

The PSK (HMAC pre-shared key, §3) is required **only in `auth_mode=required`**;
`open` (the default) and `optional` run with no key. When set, it must be
identical on every player and controller. Provide it via the `LMW_PSK` env var
(preferred) or in `config.yaml`:

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"   # generate one
```

Copy `config.example.yaml` to `config.yaml` to tune ports, the sync buffer
(`buffer_ms`, default 1500), the ready timeout (`ready_timeout_ms`, default
2000), media-library exposure (`media_bind_host`, `media_upload_token`), and
throttling. Env `LMW_PSK`, `LMW_MEDIA_BIND_HOST`, and `LMW_MEDIA_UPLOAD_TOKEN`
override the file.

## Run locally

Zero-config (default `auth_mode=open`, no PSK):

```bash
pip install -r requirements.txt
python3 broker.py
```

Strict mode (HMAC enforced):

```bash
LMW_AUTH_MODE=required \
LMW_PSK=$(python3 -c "import secrets; print(secrets.token_hex(32))") \
python3 broker.py
```

Install the optional `qrcode` package to render a scannable pairing QR on
startup (otherwise the `lmw://pair?...` URI is printed as text).

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
python3 -m pytest tests/ -q        # unit tests (envelope/clock/sync/router/
                                    # registry/auth_modes/pairing/announce/gating/
                                    # group_mgmt §18–§19/media_server §20.1) — 99 tests
python3 tests/smoke_local.py       # end-to-end (auth_mode=required): hello/
                                    # welcome, status/wall, time_sync,
                                    # prepare→ready→play_at
```

`test_media_server.py` drives a real loopback socket against the asyncio media
server (upload → sha256 guard → dedup → Range download); it resets the event
loop after each `asyncio.run` so it never pollutes the legacy-loop tests.

## Behavior notes

- **Auth pipeline** (every frame): the signature check is gated by `auth_mode`
  (§13 — `open` skips it, `optional` checks only non-empty sigs, `required`
  verifies strictly) → ts window (±30s, ±120s on the first frame) → msg_id
  dedup (5-min LRU). The ts + dedup checks run in **all** modes. In `required`,
  5 signature failures on a connection trip a 60s cooldown for that IP; other
  modes never count failures.
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

`auth_mode` decides the posture (§13). In `open` (default) traffic is neither
signed nor verified — fine for a trusted home/exhibition LAN, zero-config. For
untrusted networks set `auth_mode=required`: every control message is then
HMAC-signed and replay-protected, so commands cannot be forged or replayed, and
you can layer WSS (drop certs in `certs/`) for confidentiality. With the v1.3
default `key_mode=derived` (§17) each endpoint signs with its own
`device_key = HMAC(PSK, identity)`, so a key lifted off one always-on wall player
forges only that player — not the broker or its peers. The broker still holds
the single PSK (it derives per-endpoint keys on the fly); keep that PSK secret
and, in `open` mode especially, keep the broker off untrusted networks. Use
`key_mode=global` only to interop with endpoints not yet upgraded to v1.3, which
reverts to the shared-PSK trust model (anyone with the PSK is fully trusted).
The HTTP media library is separate from envelope auth: player downloads remain
open by URL, but set `media_upload_token` to require a bearer token for uploads,
or bind `media_bind_host: 127.0.0.1` when a reverse proxy owns LAN exposure. The
controller settings page has a matching optional media-upload token field; leave
it empty unless the broker enforces `media_upload_token`.
