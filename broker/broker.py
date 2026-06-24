"""Broker entry point: asyncio WebSocket server tying together envelope auth,
registry, routing, clock sync and the three-phase handshake.

Implements the broker-side responsibilities of protocol_spec.md (§2–§10).
Listens WS on 8770; WSS on 8771 when certs/ holds cert+key.
"""
from __future__ import annotations

import asyncio
import logging
import os
import ssl
import sys
import time
from typing import Dict, List, Optional, Set

import websockets

import clock
import discovery as discovery_mod
import envelope
import pairing
import registry as registry_mod
import router
import sync as sync_mod

try:
    import yaml
except ImportError:  # pyyaml optional; env-var config still works.
    yaml = None

log = logging.getLogger("broker")

# ---- defaults (overridable by config.yaml / env) ------------------------
DEFAULTS = {
    "ws_port": 8770,
    "wss_port": 8771,
    "discovery_port": 8772,
    "state_path": "state.json",
    "certs_dir": "certs",
    "buffer_ms": sync_mod.DEFAULT_BUFFER_MS,
    "ready_timeout_ms": sync_mod.DEFAULT_READY_TIMEOUT_MS,
    "wall_interval_ms": 1000,
    "time_sync_interval_ms": 30000,
    "auth_fail_limit": 5,
    "auth_cooldown_s": 60,
    # §13 auth_mode: open (default, zero-config) | optional | required.
    "auth_mode": envelope.AUTH_OPEN,
    # §14 topology this broker advertises: dedicated (default) | cohosted.
    "topology": "dedicated",
    # §14.5: discovery on by default so endpoints can auto-find the broker.
    "enable_discovery": True,
    # How often (ms) the broker self-announces over UDP (§14.5). 0 disables.
    "announce_interval_ms": 5000,
    # LAN IP advertised in announce/pairing. Empty -> auto-detect.
    "advertise_host": "",
}

TOPOLOGIES = ("dedicated", "cohosted")


def normalize_topology(mode) -> str:
    m = str(mode).strip().lower() if mode is not None else "dedicated"
    return m if m in TOPOLOGIES else "dedicated"


def load_config(path: Optional[str] = None) -> dict:
    """Merge defaults <- config.yaml <- env.

    PSK comes from LMW_PSK or config.yaml (env wins). auth_mode comes from
    LMW_AUTH_MODE or config.yaml (env wins). topology from LMW_TOPOLOGY.

    A PSK is **only required in `required` mode** (§13). In `open`/`optional`
    the broker runs with no key (zero-config) — `open` never verifies and
    `optional` simply lets unsigned frames through.
    """
    cfg = dict(DEFAULTS)
    cfg_path = path or os.environ.get("LMW_CONFIG", "config.yaml")
    if yaml is not None and os.path.exists(cfg_path):
        try:
            with open(cfg_path, "r", encoding="utf-8") as fh:
                loaded = yaml.safe_load(fh) or {}
            for k, v in loaded.items():
                cfg[k] = v
        except (OSError, ValueError) as exc:
            log.warning("could not read config %s: %s", cfg_path, exc)
    env_psk = os.environ.get("LMW_PSK")
    if env_psk:
        cfg["psk"] = env_psk
    env_mode = os.environ.get("LMW_AUTH_MODE")
    if env_mode:
        cfg["auth_mode"] = env_mode
    env_topo = os.environ.get("LMW_TOPOLOGY")
    if env_topo:
        cfg["topology"] = env_topo
    cfg["auth_mode"] = envelope.normalize_auth_mode(cfg.get("auth_mode"))
    cfg["topology"] = normalize_topology(cfg.get("topology"))
    if not cfg.get("psk"):
        cfg["psk"] = ""
        if cfg["auth_mode"] == envelope.AUTH_REQUIRED:
            raise SystemExit(
                "auth_mode=required but no PSK configured. Set LMW_PSK or "
                "'psk:' in config.yaml, or use auth_mode=open/optional.")
    return cfg


class ClientConn:
    """One connected endpoint (player or controller)."""

    def __init__(self, ws, ip: str):
        self.ws = ws
        self.ip = ip
        self.role: Optional[str] = None        # "player" | "controller"
        self.ident: Optional[str] = None       # device_id or controller_id
        self.addr: Optional[str] = None         # "player:<id>" / "controller:<id>"
        self.dedup = envelope.MsgIdCache()
        self.first_msg = True
        self.auth_fails = 0
        # When a thumb_meta arrives, the next binary frame is its payload.
        self.pending_thumb: Optional[dict] = None
        self._send_lock = asyncio.Lock()

    async def send_env(self, env: dict) -> None:
        async with self._send_lock:
            await self.ws.send(envelope.dumps(env))

    async def send_raw(self, data) -> None:
        async with self._send_lock:
            await self.ws.send(data)

    def __repr__(self):
        return f"<ClientConn {self.addr or self.ip}>"


class Hub:
    """Holds live connections and orchestrates message handling."""

    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.psk = cfg.get("psk", "")
        self.auth_mode = envelope.normalize_auth_mode(cfg.get("auth_mode"))
        self.topology = cfg.get("topology", "dedicated")
        self.reg = registry_mod.Registry(cfg["state_path"])
        self.sync = sync_mod.SyncManager(
            buffer_ms=cfg["buffer_ms"],
            timeout_ms=cfg["ready_timeout_ms"],
        )
        self.players: Dict[str, ClientConn] = {}       # device_id -> conn
        self.controllers: Dict[str, ClientConn] = {}   # controller_id -> conn
        self._wall_dirty = True
        self._cooldowns: Dict[str, float] = {}          # ip -> until epoch s
        self.discovery: Optional[discovery_mod.Discovery] = None

    # ---- controller presence (gates thumbnail collection, §6.4) ----------
    def controllers_online(self) -> bool:
        return len(self.controllers) > 0

    # ---- broadcast helpers ----------------------------------------------
    async def broadcast_controllers(self, env: dict) -> None:
        for conn in list(self.controllers.values()):
            try:
                await conn.send_env(env)
            except Exception:
                pass

    async def fanout_players(self, to: str, env: dict) -> int:
        targets = router.resolve_player_targets(to, self.reg, self.players)
        targets = router.dedup_conns(targets)
        sent = 0
        for conn in targets:
            try:
                await conn.send_env(env)
                sent += 1
            except Exception:
                pass
        return sent

    def mark_wall_dirty(self) -> None:
        self._wall_dirty = True

    # ---- wall snapshot (§5.2) -------------------------------------------
    def build_wall_payload(self) -> dict:
        return {
            "server_time": clock.server_time_ms(),
            "groups": self.reg.groups_snapshot(),
            "devices": [d.wall_dict() for d in self.reg.all_devices()],
        }

    def make_env(self, type_: str, payload: dict, to: str) -> dict:
        # §13: sign only when the active auth_mode calls for it; otherwise the
        # frame goes out with sig:"" (structure unchanged, parse still works).
        sign = envelope.should_sign(self.auth_mode, self.psk)
        return envelope.build_envelope(
            type_, payload, "broker", to, self.psk, sign=sign)

    def auth_meta(self) -> dict:
        """Fields advertised in welcome + announce so endpoints self-adapt
        (§13 auth_mode authority, §14 topology declaration)."""
        return {"auth_mode": self.auth_mode, "topology": self.topology}

    def broker_hint(self) -> str:
        host = self.cfg.get("advertise_host") or pairing.local_ip()
        return f"{host}:{self.cfg['ws_port']}"

    def build_announce_payload(self) -> dict:
        """UDP announce payload (§7 + §13/§14.5): carries topology, auth_mode,
        broker_hint so endpoints can auto-find and self-adapt to this broker."""
        p = {
            "broker_hint": self.broker_hint(),
            "ws_port": self.cfg["ws_port"],
        }
        p.update(self.auth_meta())
        return p

    # ---- connection lifecycle -------------------------------------------
    def _client_ip(self, ws) -> str:
        try:
            peer = ws.remote_address
            return peer[0] if peer else ""
        except Exception:
            return ""

    async def handle_connection(self, ws) -> None:
        ip = self._client_ip(ws)
        # Reject during cooldown (§3: 5 auth fails -> 60s cooldown).
        until = self._cooldowns.get(ip)
        if until and time.time() < until:
            await ws.close(code=1008, reason="cooldown")
            return
        conn = ClientConn(ws, ip)
        try:
            async for raw in ws:
                t2 = clock.server_time_ms()  # capture receive time ASAP (§8)
                if isinstance(raw, (bytes, bytearray)):
                    await self._handle_binary(conn, bytes(raw))
                    continue
                await self._handle_text(conn, raw, t2)
        except websockets.ConnectionClosed:
            pass
        except Exception as exc:  # one bad connection must not kill broker
            log.warning("connection error from %s: %s", conn.addr or ip, exc)
        finally:
            await self._cleanup(conn)

    def _register_auth_fail(self, conn: ClientConn) -> bool:
        """Return True if the connection should be dropped + cooled down."""
        conn.auth_fails += 1
        if conn.auth_fails >= self.cfg["auth_fail_limit"]:
            self._cooldowns[conn.ip] = time.time() + self.cfg["auth_cooldown_s"]
            return True
        return False

    async def _handle_text(self, conn: ClientConn, raw: str, t2: int) -> None:
        try:
            env = envelope.parse(raw)
        except envelope.MalformedEnvelope as exc:
            log.debug("malformed envelope from %s: %s", conn.addr or conn.ip, exc)
            return
        # §13 verification pipeline. The sig gate depends on auth_mode; the
        # ts-window + msg_id dedup checks run in EVERY mode (replay hygiene).
        if not envelope.verify_inbound(env, self.psk, self.auth_mode):
            # Auth-fail counter + cooldown apply ONLY in `required` (§13).
            if self.auth_mode == envelope.AUTH_REQUIRED:
                if self._register_auth_fail(conn):
                    await conn.ws.close(code=1008, reason="auth")
            return
        if not envelope.check_ts(env["ts"], first=conn.first_msg):
            return
        if conn.dedup.seen(env["msg_id"]):
            return
        conn.first_msg = False
        conn.auth_fails = 0
        await self._dispatch(conn, env, t2)

    async def _cleanup(self, conn: ClientConn) -> None:
        if conn.role == "player" and conn.ident:
            self.players.pop(conn.ident, None)
            self.reg.set_offline(conn.ident)
            self.mark_wall_dirty()
        elif conn.role == "controller" and conn.ident:
            self.controllers.pop(conn.ident, None)

    # ---- dispatch --------------------------------------------------------
    async def _dispatch(self, conn: ClientConn, env: dict, t2: int) -> None:
        mtype = env["type"]
        payload = env["payload"]
        if mtype == "hello":
            await self._on_hello(conn, env)
            return
        # Must say hello before anything else.
        if conn.role is None:
            return
        handler = {
            "status": self._on_status,
            "time_sync": self._on_time_sync,
            "prepare": self._on_prepare,
            "ready": self._on_ready,
            "thumb_meta": self._on_thumb_meta,
            "cache_prefetch": self._on_route_to_players,
            "playlist": self._on_playlist,
            "pause": self._on_route_to_players,
            "resume": self._on_route_to_players,
            "stop": self._on_route_to_players,
            "next": self._on_route_to_players,
            "prev": self._on_route_to_players,
            "set_volume": self._on_route_to_players,
            "set_mute": self._on_route_to_players,
            "set_audio_master": self._on_route_to_players,
            "assign_group": self._on_assign_group,
            "set_schedule": self._on_route_to_players,
            "ota_check": self._on_route_to_players,
            "ota_apply": self._on_route_to_players,
            "reboot": self._on_route_to_players,
            "resume_last": self._on_route_to_players,
            "ack": self._on_ack,
            "error": self._on_error,
        }.get(mtype)
        if handler is None:
            log.debug("unknown type %s from %s", mtype, conn.addr)
            return
        if mtype == "time_sync":
            await handler(conn, env, t2)
        else:
            await handler(conn, env)

    async def _on_hello(self, conn: ClientConn, env: dict) -> None:
        p = env["payload"]
        role = p.get("role")
        if role == "player":
            device_id = p.get("device_id")
            if not device_id:
                return
            dev = self.reg.register(
                device_id,
                device_name=p.get("device_name", ""),
                platform=p.get("platform", ""),
                app_version=p.get("app_version", ""),
                ip=p.get("ip", "") or conn.ip,
                screen=p.get("screen"),
                capabilities=p.get("capabilities"),
                group_id=p.get("group_id"),
            )
            conn.role = "player"
            conn.ident = device_id
            conn.addr = f"player:{device_id}"
            self.players[device_id] = conn
            welcome = self.make_env("welcome", {
                "assigned": True,
                "server_time": clock.server_time_ms(),
                "v": envelope.PROTOCOL_VERSION,
                "minor": envelope.PROTOCOL_MINOR,
                "group_id": dev.group_id,
                "controllers_online": len(self.controllers),
                **self.auth_meta(),
            }, conn.addr)
            await conn.send_env(welcome)
            self.mark_wall_dirty()
        elif role == "controller":
            controller_id = p.get("controller_id")
            if not controller_id:
                return
            conn.role = "controller"
            conn.ident = controller_id
            conn.addr = f"controller:{controller_id}"
            self.controllers[controller_id] = conn
            welcome = self.make_env("welcome", {
                "assigned": True,
                "server_time": clock.server_time_ms(),
                "v": envelope.PROTOCOL_VERSION,
                "minor": envelope.PROTOCOL_MINOR,
                "snapshot": self.build_wall_payload(),
                **self.auth_meta(),
            }, conn.addr)
            await conn.send_env(welcome)
        # unknown role: ignore.

    async def _on_status(self, conn: ClientConn, env: dict) -> None:
        if conn.role != "player":
            return
        self.reg.update_status(conn.ident, env["payload"])
        self.mark_wall_dirty()

    async def _on_time_sync(self, conn: ClientConn, env: dict, t2: int) -> None:
        t1 = env["payload"].get("t1")
        if t1 is None:
            return
        # t3 stamped as late as possible, right before building the reply.
        ack_payload = clock.build_time_sync_ack_payload(t1, t2)
        ack = self.make_env("time_sync_ack", ack_payload, conn.addr or "broker")
        await conn.send_env(ack)

    # ---- three-phase handshake (§9) -------------------------------------
    async def _on_prepare(self, conn: ClientConn, env: dict) -> None:
        if conn.role != "controller":
            return
        p = env["payload"]
        group_id = p.get("group_id")
        playlist_id = p.get("playlist_id")
        if not group_id:
            return
        members = set(self.reg.members(group_id, online_only=True))
        # group sync mode: default true unless explicitly false in meta.
        meta = next((g for g in self.reg.groups_snapshot()
                     if g["group_id"] == group_id), None)
        sync_flag = meta["sync"] if meta else True
        start_index = p.get("start_index", 0)
        seek_ms = p.get("seek_ms", 0)

        if not sync_flag or not members:
            # sync=false -> play immediately on each member, no handshake.
            await self._emit_play_at(group_id, playlist_id, start_index,
                                     seek_ms, clock.server_time_ms(),
                                     list(members))
            return

        # Fan the prepare out to members and open a ready-collection session.
        self.sync.start(env["msg_id"], group_id, playlist_id, members,
                        start_index=start_index, seek_ms=seek_ms)
        fwd = self.make_env("prepare", p, f"group:{group_id}")
        await self.fanout_players(f"group:{group_id}", fwd)

    async def _on_ready(self, conn: ClientConn, env: dict) -> None:
        if conn.role != "player":
            return
        p = env["payload"]
        device_id = p.get("device_id") or conn.ident
        dev = self.reg.get(device_id)
        group_id = dev.group_id if dev else None
        if group_id is None:
            return
        if not p.get("ready", True):
            return
        session = self.sync.on_ready(group_id, device_id)
        if session is not None:
            play_at = self.sync.complete(session)
            await self._emit_play_at(session.group_id, session.playlist_id,
                                     session.start_index, session.seek_ms,
                                     play_at, sorted(session.ready))

    async def _emit_play_at(self, group_id: str, playlist_id, start_index: int,
                            seek_ms: int, play_at: int,
                            targets: List[str]) -> None:
        payload = {
            "playlist_id": playlist_id,
            "group_id": group_id,
            "start_index": start_index,
            "seek_ms": seek_ms,
            "play_at": play_at,
        }
        # Address whoever is ready; for an empty/all case use the group.
        if targets:
            for device_id in targets:
                conn = self.players.get(device_id)
                if conn is None:
                    continue
                env = self.make_env("play_at", payload, f"player:{device_id}")
                try:
                    await conn.send_env(env)
                except Exception:
                    pass
        else:
            env = self.make_env("play_at", payload, f"group:{group_id}")
            await self.fanout_players(f"group:{group_id}", env)

    async def check_sync_timeouts(self) -> None:
        """Called periodically: fire play_at for sessions past their 2s
        deadline using whoever is ready (§9.2)."""
        for session in self.sync.expired_sessions():
            ready = session.ready_members()
            play_at = self.sync.complete(session)
            await self._emit_play_at(session.group_id, session.playlist_id,
                                     session.start_index, session.seek_ms,
                                     play_at, ready)

    # ---- media / routing -------------------------------------------------
    async def _on_playlist(self, conn: ClientConn, env: dict) -> None:
        if conn.role != "controller":
            return
        p = env["payload"]
        group_id = p.get("group_id")
        if group_id:
            self.reg.set_group_meta(
                group_id,
                playlist_id=p.get("playlist_id"),
                sync=p.get("sync"),
            )
            self.mark_wall_dirty()
        to = env.get("to") or (f"group:{group_id}" if group_id else "all")
        fwd = self.make_env("playlist", p, to)
        await self.fanout_players(to, fwd)

    async def _on_route_to_players(self, conn: ClientConn, env: dict) -> None:
        """Generic controller->players fan-out preserving payload (§9.3/§10)."""
        if conn.role != "controller":
            return
        to = env.get("to")
        if not to or router.parse_addr(to)[0] not in (
                "all", "player", "group"):
            # Derive target from payload if `to` is broker/unset.
            p = env["payload"]
            if p.get("device_id"):
                to = f"player:{p['device_id']}"
            elif p.get("group_id"):
                to = f"group:{p['group_id']}"
            else:
                to = "all"
        fwd = self.make_env(env["type"], env["payload"], to)
        await self.fanout_players(to, fwd)

    async def _on_assign_group(self, conn: ClientConn, env: dict) -> None:
        if conn.role != "controller":
            return
        p = env["payload"]
        device_id = p.get("device_id")
        group_id = p.get("group_id")
        if device_id and group_id:
            self.reg.assign_group(device_id, group_id)
            self.mark_wall_dirty()
            # Inform the player of its new group.
            target = self.players.get(device_id)
            if target is not None:
                fwd = self.make_env("assign_group", p, f"player:{device_id}")
                try:
                    await target.send_env(fwd)
                except Exception:
                    pass

    # ---- thumbnails (§6.4) ----------------------------------------------
    async def _on_thumb_meta(self, conn: ClientConn, env: dict) -> None:
        if conn.role != "player":
            return
        # Remember meta; the next binary frame on this conn is the JPEG.
        conn.pending_thumb = env
        # Forward the meta to all controllers immediately.
        if self.controllers_online():
            fwd = self.make_env("thumb_meta", env["payload"], "all")
            await self.broadcast_controllers(fwd)

    async def _handle_binary(self, conn: ClientConn, data: bytes) -> None:
        # A binary frame is only meaningful right after a thumb_meta (§6.4).
        if conn.role != "player" or conn.pending_thumb is None:
            return
        conn.pending_thumb = None
        if self.controllers_online():
            for c in list(self.controllers.values()):
                try:
                    await c.send_raw(data)
                except Exception:
                    pass

    # ---- ack / error (§10) ----------------------------------------------
    async def _on_ack(self, conn: ClientConn, env: dict) -> None:
        # Relay player acks to controllers so UIs can confirm commands.
        if conn.role == "player":
            fwd = self.make_env("ack", env["payload"], "all")
            await self.broadcast_controllers(fwd)

    async def _on_error(self, conn: ClientConn, env: dict) -> None:
        if conn.role == "player":
            fwd = self.make_env("error", env["payload"], "all")
            await self.broadcast_controllers(fwd)

    # ---- background loops ------------------------------------------------
    async def wall_loop(self) -> None:
        interval = self.cfg["wall_interval_ms"] / 1000.0
        while True:
            await asyncio.sleep(interval)
            if self._wall_dirty and self.controllers_online():
                self._wall_dirty = False
                env = self.make_env("wall", self.build_wall_payload(), "all")
                await self.broadcast_controllers(env)

    async def sync_timeout_loop(self) -> None:
        while True:
            await asyncio.sleep(0.1)
            try:
                await self.check_sync_timeouts()
            except Exception as exc:
                log.warning("sync timeout loop error: %s", exc)

    async def announce_loop(self) -> None:
        """Periodically self-announce over UDP so endpoints auto-find this
        broker (§14.5). Disabled when announce_interval_ms <= 0."""
        interval_ms = self.cfg.get("announce_interval_ms", 0)
        if not interval_ms or interval_ms <= 0:
            return
        interval = interval_ms / 1000.0
        while True:
            await asyncio.sleep(interval)
            if self.discovery is None:
                continue
            try:
                env = self.make_env("announce", self.build_announce_payload(),
                                     "all")
                self.discovery.broadcast(env)
            except Exception as exc:
                log.debug("announce broadcast failed: %s", exc)

    def on_discover(self, env: dict, addr) -> None:
        """A discover packet arrived -> unicast our announce back (§7/§14.5)."""
        if self.discovery is None:
            return
        try:
            reply = self.make_env("announce", self.build_announce_payload(),
                                   "all")
            self.discovery.send_to(reply, addr)
        except Exception as exc:
            log.debug("discover reply failed: %s", exc)

    def on_announce(self, env: dict, addr) -> None:
        """UDP announce -> refresh last_ip in the registry (§7)."""
        p = env.get("payload", {})
        device_id = p.get("device_id")
        ip = p.get("ip") or (addr[0] if addr else "")
        if device_id:
            dev = self.reg.get(device_id)
            if dev is not None and ip:
                dev.last_ip = ip
                self.reg.save()


def build_ssl_context(certs_dir: str) -> Optional[ssl.SSLContext]:
    """Return an SSLContext if certs_dir holds cert.pem + key.pem, else None."""
    cert = os.path.join(certs_dir, "cert.pem")
    key = os.path.join(certs_dir, "key.pem")
    if os.path.exists(cert) and os.path.exists(key):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        return ctx
    return None


async def run(cfg: dict, *, hub: Optional["Hub"] = None,
              ready_event: Optional[asyncio.Event] = None) -> "Hub":
    """Start the broker servers + background loops and run until cancelled.

    Returns the live `Hub` (useful when embedded). When `hub` is provided it is
    used as-is (the caller may inspect it); otherwise one is built from `cfg`.
    `ready_event`, if given, is set once all servers are listening — a cohost
    player process can await it before connecting its local client (§14.2).
    """
    hub = hub or Hub(cfg)
    servers = []

    ws_server = await websockets.serve(
        hub.handle_connection, "0.0.0.0", cfg["ws_port"],
        ping_interval=20, ping_timeout=20, max_size=4 * 1024 * 1024,
    )
    servers.append(ws_server)
    log.info("broker WS listening on :%d (auth_mode=%s topology=%s)",
             cfg["ws_port"], hub.auth_mode, hub.topology)

    ssl_ctx = build_ssl_context(cfg["certs_dir"])
    wss_enabled = ssl_ctx is not None
    if wss_enabled:
        wss_server = await websockets.serve(
            hub.handle_connection, "0.0.0.0", cfg["wss_port"],
            ssl=ssl_ctx, ping_interval=20, ping_timeout=20,
            max_size=4 * 1024 * 1024,
        )
        servers.append(wss_server)
        log.info("broker WSS listening on :%d", cfg["wss_port"])
    else:
        log.info("no certs in %s -> WSS disabled", cfg["certs_dir"])

    if cfg.get("enable_discovery"):
        hub.discovery = discovery_mod.Discovery(
            hub.psk, hub.on_announce, cfg["discovery_port"],
            auth_mode=hub.auth_mode, on_discover=hub.on_discover)
        try:
            await hub.discovery.start()
            log.info("UDP discovery on :%d", cfg["discovery_port"])
        except OSError as exc:
            hub.discovery = None
            log.warning("discovery disabled: %s", exc)

    tasks = [
        asyncio.create_task(hub.wall_loop()),
        asyncio.create_task(hub.sync_timeout_loop()),
    ]
    if hub.discovery is not None:
        tasks.append(asyncio.create_task(hub.announce_loop()))

    # Emit the pairing block so an operator can scan to onboard endpoints (§15).
    try:
        pairing.print_pairing(cfg, wss=wss_enabled)
    except Exception as exc:  # never let cosmetics break startup
        log.debug("pairing print skipped: %s", exc)

    if ready_event is not None:
        ready_event.set()

    try:
        await asyncio.Future()  # run forever
    finally:
        for t in tasks:
            t.cancel()
        for s in servers:
            s.close()
            await s.wait_closed()
        if hub.discovery:
            hub.discovery.stop()
    return hub


async def run_broker(cfg: Optional[dict] = None, *,
                     ready_event: Optional[asyncio.Event] = None) -> "Hub":
    """Embeddable entry point (§14.2 cohosted).

    A player process can `import broker` and `await broker.run_broker(cfg)` to
    launch the broker in-process — no separate machine or CLI needed. When
    `cfg` is None the standard config (defaults <- config.yaml <- env) is used.
    From the wire side this is identical to a dedicated broker; only `topology`
    advertised in welcome/announce differs.
    """
    if cfg is None:
        cfg = load_config()
    return await run(cfg, ready_event=ready_event)


def main(argv=None) -> int:
    logging.basicConfig(
        level=os.environ.get("LMW_LOG", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    cfg = load_config()
    try:
        asyncio.run(run(cfg))
    except KeyboardInterrupt:
        log.info("shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(main())
