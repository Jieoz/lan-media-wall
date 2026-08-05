# LAN Media Wall — Broker

Central coordinator for the LAN media wall. Players (Windows/Android) and
controllers (Flutter) connect only to this broker over WebSocket; the broker
owns the device registry, group assignments, the master clock, status
aggregation, and command fan-out.

## v1.19.1 — transparent transport-intent routing

Broker remains payload-transparent for `transport_mode`; the same release SHA
routes the Player's durable `broker` / `auto` / `p2p` result and status readback
before the old client link closes. Config results are unicast only to the
initiating Controller: modern requests use `request_id`; legacy no-ID requests
are serialized per target Player and remain bound to its authenticated identity.

## v1.19.0 — atomic identity-bound thumbnails

Controller presence is broadcast when a Controller joins or leaves, including
when Players connected first. `thumb_meta` remains paired with its JPEG until
the binary frame arrives; each Controller receives both frames under one send
lock. The Broker validates byte length and replaces payload `device_id` with the
authenticated Player identity before forwarding.

This implements the broker-side responsibilities of
[`../protocol_spec.md`](../protocol_spec.md) (§2–§10, plus the v1.2 additions
§13–§15, the v1.3 derived keys §17, and the v1.4 group CRUD §18 / device config
§19 / media library §20 / prefetch barrier §21). That spec is the contract —
field names and semantics here follow it exactly.

## v1.18.7 candidate — authoritative synchronized loop sessions

For group and single-device `prepare`, the Broker owns the ready barrier and
emits one `sync_session_id` consistently in both `prepare` and the resulting
`play_at`. Players use that Broker session plus the shared master-clock start to
calculate common loop boundaries; the Broker still carries control/time/status
only and never proxies media bytes. P2P keeps the same optional fields for
controller-online compatibility, but is not the unattended long-term authority.


## v1.18.2 — safe remote configuration

`configure_device` is a low-risk patch only: display name, group, volume, and
mute. A player advertises capabilities plus a revisioned redacted snapshot, and
returns a per-field `config_patch_result`. Transport changes are sent only as
`transport_configure`; PSK replacement is sent only as `rotate_device_key`.
Neither secrets nor pairing identity appear in snapshots or results.

The broker routes these commands and their results without interpreting secret
values. It derives player identity from the authenticated connection, not a
payload `device_id`.


## v1.17.0 — cache cleanup / inventory routing

Phase B routes the cache-lifecycle control plane through the broker without
letting either role forge the other side:

- controller→player only: `cache_cleanup`, `cache_inventory`
- player→controller only: `cache_cleanup_result`, `cache_inventory_result`
- results are **unicast** back to the initiating controller (not broadcast)
- controller-forged results and player-forged requests are rejected
- fingerprint gate stays byte-aligned with player/controller (`device:<id>` /
  `group:<gid>` / `all`)

`tests/test_cache_cleanup_routing.py` locks both directions and the unicast path.

## v1.15.0 — playlist/loop parity contract

The broker continues to forward playlist payloads without rewriting their
`mode`, canonical `loop_mode`, compatibility `loop`, or per-replace `push_id`.
`tests/test_playlist_loopmode_parity.py` locks that controller → broker → player
contract so Broker and P2P retain identical replace/append and three-mode loop
semantics. Media progress itself is derived by the controller from player
`status.cache`; the broker only preserves and aggregates those status fields.

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

Normal `restart` messages are routed unchanged to selected players. On Android this is an app-only `RESTART_APP` daemon dispatch that preserves device uptime and Wi-Fi; whole-device `reboot` remains a separate high-risk command.

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

## Run with Docker Compose (推荐)

```bash
cd broker
docker compose up -d
```

就这一条。首次启动会在 `./data/` 下生成 `state.json`,`auth_mode` 默认 `open`
(零配置,不需要 PSK)。查看状态和日志:

```bash
docker compose ps
docker compose logs -f
```

要改配置:把 `config.example.yaml` 复制成 `data/config.yaml` 再改 —— 容器已经把
`LMW_CONFIG` 指向 `/data/config.yaml`。要开签名校验,在 compose 的 `environment:`
里设 `LMW_AUTH_MODE: required` 和 `LMW_PSK: <32+ 字节 hex>`(三端必须同一个 PSK)。

### 为什么用 `network_mode: host`

broker 的 UDP 自动发现(§7/§14.5)往 `255.255.255.255` 发广播,让播放端和控制端
自己找到 broker。**广播不跨 Docker bridge 网络** —— 用 bridge + 端口映射的话,
WebSocket 能连上,但自动发现会静默失效,现场表现为「盒子扫不到 broker,必须手填 IP」。

如果环境不能用 host 网络(如 Docker Desktop for Mac/Windows),`docker-compose.yml`
末尾有 bridge 备选配置,但要接受手填 IP 这个代价。

### 端口

| 端口 | 用途 |
|---|---|
| 8770/tcp | WebSocket(主控制通道) |
| 8771/tcp | WSS —— 仅当 `/data/certs/` 有 `cert.pem` + `key.pem` 时启用 |
| 8772/udp | UDP 自动发现 |
| 8773/tcp | 媒体库上传/下载(§20.1),控制端本地上传走这个口 |

`state.json`(设备注册表 + 分组)、可选的 `config.yaml`、`certs/`、上传的媒体都在
挂载的 `/data` 里,重启和重建容器都不会丢。

启动日志正常长这样(没放证书时 `WSS disabled` 是预期的):

```
broker WS listening on :8770 (auth_mode=open key_mode=derived topology=dedicated)
no certs in certs -> WSS disabled
broker media library on 0.0.0.0:8773 (dir=media, max=500MB, open-upload)
UDP discovery on :8772
```

### 网络不稳时怎么拿到代码

git 传整个仓库(4500+ 对象)在链路不稳时容易断在 `Compressing objects: 100%`
之后,报 `RPC failed; curl 56 GnuTLS recv error` / `early EOF`。两个绕法:

```bash
# 浅克隆:只取最新一次提交,.git 从 15M 降到 1.4M
git clone --depth=1 https://github.com/Jieoz/lan-media-wall.git

# 还是断就用 tarball(单次 HTTP 下载,整仓约 1MB,不走 git pack 传输)
curl -fsSL -o lmw.tar.gz https://codeload.github.com/Jieoz/lan-media-wall/tar.gz/refs/heads/main
tar xzf lmw.tar.gz && cd lan-media-wall-main/broker
```

### 更新

```bash
cd lan-media-wall
git fetch --depth=1 origin main
git reset --hard FETCH_HEAD
cd broker && docker compose up -d --build
```

**`--build` 必须加。** broker 是本地源码构建,不是拉远程镜像。少了它,新代码不会
进镜像 —— 命令照样成功、容器照样 healthy,但跑的还是旧代码。想确认真换了,比对
`docker compose ps -q` 前后的容器 ID。

**浅克隆的仓库不能用 `git pull`。** 浅仓库和远端没有共同祖先,git 判定分叉:
`git pull` 报 `Need to specify how to reconcile divergent branches`,`git pull --ff-only`
报 `Not possible to fast-forward`,而 `git pull --depth=1` 更糟 —— 它可能直接说
`Already up to date.` 退出码 0,看着成功实际一个字节都没更新。上面那条
`fetch` + `reset --hard` 是浅仓库唯一可靠的写法。

用 `FETCH_HEAD` 而不是 `origin/main`:如果当初是 `--branch <tag>` 克隆的,远端
refspec 里没有 `main`,`origin/main` 这个引用根本不存在,`reset` 会失败 —— 而且
**版本号不变、退出码仍是 0**,又一个看着成功实际没更新的坑。`FETCH_HEAD` 由上一条
`fetch` 直接产生,跟当初怎么克隆无关。

`reset --hard` 会丢弃本地对**被跟踪文件**的修改。`data/` 已在 `.gitignore` 里,
不受影响,注册表和媒体都安全。

tarball 装的没有 `.git`:重新下 tarball 解压,把新的 `*.py` 覆盖进去(**不要覆盖
`data/`**),然后 `docker compose up -d --build`。

`docker compose pull` 对本项目没有意义(没有发布到 registry 的镜像),不要用。

### 常用操作

```bash
# 在 broker/ 目录下:
docker compose logs -f       # 看日志
docker compose ps            # 看状态,要 healthy
docker compose restart       # 重启,数据不丢
docker compose down          # 停掉并删容器,data/ 保留

# 不在 broker/ 目录时用容器名(任何位置都能跑):
docker logs -f lmw-broker
docker logs --tail 50 lmw-broker
```

`docker compose …` 靠当前目录找 `docker-compose.yml`。在仓库根目录跑会报
`no configuration file provided: not found` —— 要么 `cd broker`,要么用
`docker logs lmw-broker`。

healthcheck 探的是 **8773**(媒体 HTTP),不是 8770。早期版本探 8770 会让
websockets 每 30 秒打一条 `connection closed`,把真日志淹没;已改掉。若你还在
刷那条,按上面的更新命令重建一次容器即可。

## Run on Synology (Docker)

Synology 的 Container Manager 也能跑 compose:把 `broker/` 传到共享文件夹,新建项目
指向这份 `docker-compose.yml` 即可。若手工建容器,记得选 host 网络(否则自动发现失效),
并挂一个共享文件夹到 `/data`。

手动 `docker run` 等价写法:

```bash
docker build -t lmw-broker .
docker run -d --name lmw-broker --network host \
  -v /volume1/docker/lmw-broker:/data \
  lmw-broker
```

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
