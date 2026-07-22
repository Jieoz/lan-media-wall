"""LAN Media Wall — Windows player entrypoint.

Wires every subsystem into one process:
  config/state → mpv watchdog → WS client → status/thumbnail loops → handlers.

Run:  python main.py --config config.yaml
The PSK is read from env LMW_PSK if set, else from the config file.

This file is the orchestrator: it owns protocol semantics (§4 hello, §5 status,
§6 cache/playlist, §6.4 thumbnails, §8 clock, §9 handshake + controls, §10
resume_last, §11 black-screen safety). Blocking mpv IPC calls are pushed to a
thread executor so the asyncio loop never stalls.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
import threading
import time
from typing import Any, Dict, List, Optional

import config as config_mod
import auth as auth_mod
import topology as topology_mod
import pairing as pairing_mod
import playlist_ops as playlist_ops
from playback_modes import MusicPlaylist, PlaybackMode, PlaybackModeState, ShuffleBag
from loop_mode import LoopMode, resolve_loop_mode
from clock import ClockSync, now_ms
from downloader import Downloader
from versioning import APP_VERSION
from websocket_client import BrokerClient
import cache_cleanup
import cache_live
import cache_refs

log = logging.getLogger("lmw.main")

# Soft imports for the OS-coupled subsystems so this file imports on CI/Linux.
try:
    from watchdog import MpvWatchdog
except Exception:  # pragma: no cover
    MpvWatchdog = None  # type: ignore
try:
    from thumbnailer import Thumbnailer
except Exception:  # pragma: no cover
    Thumbnailer = None  # type: ignore
try:
    from kiosk_win import KioskGuard
except Exception:  # pragma: no cover
    KioskGuard = None  # type: ignore
try:
    from discovery import DiscoveryResponder
except Exception:  # pragma: no cover
    DiscoveryResponder = None  # type: ignore
# §14 transports — import-guarded (need `websockets`); pure decision logic in
# topology_mod is always available even if these aren't.
try:
    import discovery_probe as discovery_probe_mod
except Exception:  # pragma: no cover
    discovery_probe_mod = None  # type: ignore
try:
    from p2p_server import P2PServer
except Exception:  # pragma: no cover
    P2PServer = None  # type: ignore
try:
    import cohost as cohost_mod
except Exception:  # pragma: no cover
    cohost_mod = None  # type: ignore


VALID_STATES = {"playing", "paused", "idle", "buffering", "downloading"}

# §6.3: default per-image dwell when a playlist item omits duration_ms (kept in
# sync with the Android player's DEFAULT_IMAGE_DWELL_MS).
DEFAULT_IMAGE_DWELL_MS = 5000


class Player:
    def __init__(self, cfg: config_mod.Config, *, cohost: Optional[bool] = None):
        self.cfg = cfg
        self.state = config_mod.PersistentState.load(cfg.state_dir)
        # §19: remote broker overrides win over yaml defaults for next dial.
        config_mod.apply_state_transport(self.cfg, self.state)
        self.loop: Optional[asyncio.AbstractEventLoop] = None

        self.device_id = self.state.device_id
        self.device_name = self.state.device_name(
            cfg.get("device", "name"))
        self.group_id = self.state.group_id if self.state.group_id != "default" \
            else (cfg.get("device", "group_id") or "default")
        self.ip = config_mod.detect_ip(cfg.get("broker", "host", default="8.8.8.8"))

        # §13/§17: shared auth state — starts from configured mode + key mode,
        # adopts the coordinator's mode once welcome/announce reveals it. In
        # derived mode a PSK-less end signs with its paired device_key and
        # verifies broker frames via the paired broker_key (§17.4).
        identity = self.cfg.identity or f"player:{self.device_id}"
        broker_key = self.cfg.broker_key
        verify_keys = {"broker": broker_key} if broker_key else None
        self.auth = auth_mod.AuthState(
            cfg.auth_mode, cfg.psk,
            key_mode=cfg.key_mode, identity=identity,
            device_key=cfg.device_key, verify_keys=verify_keys)
        # §14: cohost flag (CLI overrides config).
        self.cohost = bool(cfg.get("topology", "cohost", default=False)
                           if cohost is None else cohost)
        self.cohost_broker = None  # set when we spawn an in-process broker

        self.clock = ClockSync()
        self.downloader = Downloader(
            cfg.cache_dir, on_change=self._on_cache_change)

        # playback state
        self.play_state = "idle"
        self.playlist: Optional[Dict[str, Any]] = None
        self.index = 0
        current_mode = PlaybackMode.parse(self.state.runtime_mode) or PlaybackMode.VISUAL
        previous_mode = (PlaybackMode.parse(self.state.previous_active_mode)
                         or PlaybackMode.VISUAL)
        self.runtime_mode = PlaybackModeState(current_mode, previous_mode)
        self.mode_generation = 0
        self.music_playlist: Optional[Dict[str, Any]] = self.state.music_playlist
        self.music_shuffle = ShuffleBag[str]()
        self.music_current_item_id: Optional[str] = None
        self.music_failures: set[str] = set()
        self.music_play_count = 0
        self.music_started_monotonic = 0.0
        # §19: volume/muted are persisted config preferences — restore across
        # reboots (fall back to the shipped defaults on a fresh device).
        self.volume = self.state.volume if self.state.volume is not None else 80
        self.muted = self.state.muted if self.state.muted is not None else False
        self.audio_master = True
        self._cache_generation_lock = threading.RLock()
        self.controller_present = bool(
            cfg.get("thumbnail", "always_collect", default=False))
        self._errors: List[str] = []

        self._play_task: Optional[asyncio.Task] = None
        self._barrier_task: Optional[asyncio.Task] = None
        self._resume_task: Optional[asyncio.Task] = None
        self._restore_task: Optional[Any] = None
        # §6.3 carousel: pending "hold this image for duration_ms, then advance"
        # timer. Cancelled by any new prepare/play_at/advance/stop.
        self._dwell_task: Optional[asyncio.Task] = None
        self._cache_dirty = asyncio.Event()
        # §19: transport rebuild serializes against overlapping configure_device.
        self._transport_rebuild_lock = asyncio.Lock()
        self._ws_task: Optional[asyncio.Task] = None

        # OS-coupled subsystems (created in start())
        self.watchdog = None
        self.mpv = None
        self.kiosk = None
        self.thumbnailer = None
        self.discovery = None

        # §14: transport is chosen at run() time from discovery (client vs p2p
        # server). decision/ws are filled by _setup_transport().
        self.decision: Optional[topology_mod.Decision] = None
        self.ws = None  # BrokerClient | P2PServer

    # --- mpv helper: run a blocking IPC call off the event loop -------
    async def _mpv(self, fn, *args, **kwargs):
        if self.mpv is None:
            return None
        return await asyncio.to_thread(self._mpv_sync, fn, *args, **kwargs)

    def _mpv_sync(self, fn, *args, **kwargs):
        try:
            return getattr(self.mpv, fn)(*args, **kwargs)
        except Exception as exc:
            log.debug("mpv.%s failed: %s", fn, exc)
            return None

    # --- §14 transport selection -------------------------------------
    def _discover_decision(self) -> topology_mod.Decision:
        """Decide client vs p2p-server from a UDP discovery probe (§14.5).

        Blocking (socket + timeout) — call via to_thread. Falls back to the
        configured broker as a pseudo-discovery when auto-discovery is off or
        the probe module is unavailable, so behavior degrades gracefully."""
        cohost = self.cohost
        fallback_mode = self.auth.mode
        fallback_key_mode = self.auth.key_mode
        auto = bool(self.cfg.get("topology", "auto", default=True))
        p2p_port = int(self.cfg.get("topology", "p2p_listen_port", default=8770))
        timeout = float(self.cfg.get("topology", "discover_timeout_s", default=3.0))

        if cohost:
            # operator intent wins; no probe needed (§14.2).
            return topology_mod.decide_topology(
                None, cohost=True, fallback_auth_mode=fallback_mode,
                fallback_key_mode=fallback_key_mode, p2p_listen_port=p2p_port)

        found = None
        if auto and discovery_probe_mod is not None:
            try:
                found = discovery_probe_mod.probe_for_broker(
                    psk=self.cfg.psk, auth_mode=self.auth.mode,
                    device_id=self.device_id, timeout_s=timeout,
                    key_mode=self.auth.key_mode,
                    device_key=self.auth.device_key)
            except Exception as exc:
                log.warning("discovery probe failed (%s); using configured broker",
                            exc)
        if found is None and not auto:
            # auto off → trust the configured broker host/port (mode A).
            found = topology_mod.BrokerFound(
                host=self.cfg.get("broker", "host", default="127.0.0.1"),
                port=int(self.cfg.get("broker", "port", default=8770)),
                auth_mode=self.auth.mode, key_mode=self.auth.key_mode)
        return topology_mod.decide_topology(
            found, cohost=False, fallback_auth_mode=fallback_mode,
            fallback_key_mode=fallback_key_mode, p2p_listen_port=p2p_port)

    def _build_transport(self, decision: topology_mod.Decision):
        """Construct the BrokerClient or P2PServer for `decision` (§14)."""
        self.auth.adopt(decision.auth_mode)
        self.auth.adopt_key_mode(decision.key_mode)
        interval = float(self.cfg.get("time_sync_interval_s", default=30))

        if decision.role == topology_mod.ROLE_P2P_SERVER:
            if P2PServer is None:
                raise RuntimeError("p2p server unavailable (websockets missing)")
            log.info("topology=p2p → running as WS server on :%d (controller=clock)",
                     decision.listen_port)
            return P2PServer(
                psk=self.cfg.psk, device_id=self.device_id,
                group_id=self.group_id, clock=self.clock, auth_state=self.auth,
                on_connect=self._on_p2p_connect, on_message=self._on_message,
                listen_port=int(decision.listen_port or 8770),
                time_sync_interval_s=interval)

        # client role (mode A or B) ------------------------------------
        if decision.cohost_broker:
            self._spawn_cohost_broker()
        # discovered/cohost brokers are plain WS (the hint is host:ws_port);
        # WSS is only used for an explicitly-configured dedicated broker.
        if not decision.cohost_broker and self.cfg.get("broker", "use_wss",
                                                        default=False):
            url = f"wss://{decision.host}:{int(decision.port) + 1}"
        else:
            url = f"ws://{decision.host}:{decision.port}"
        log.info("topology=%s → connecting as client to %s (auth_mode=%s)",
                 decision.topology, url, self.auth.mode)
        return BrokerClient(
            url, psk=self.cfg.psk, device_id=self.device_id, clock=self.clock,
            on_connect=self._on_connect, on_message=self._on_message,
            time_sync_interval_s=interval, auth_state=self.auth)

    def _spawn_cohost_broker(self) -> None:
        """§14.2: start the broker in-process so we *are* the coordinator."""
        if cohost_mod is None:
            log.error("cohost requested but cohost module unavailable")
            self._errors.append("cohost-unavailable")
            return
        bcfg = cohost_mod.build_broker_config(
            self.cfg.psk, auth_mode=self.auth.mode, key_mode=self.auth.key_mode,
            ws_port=int(self.cfg.get("topology", "p2p_listen_port", default=8770)),
            discovery_port=int(self.cfg.get("discovery", "udp_port", default=8772)))
        self.cohost_broker = cohost_mod.CohostBroker(bcfg)
        if not self.cohost_broker.start():
            self._errors.append("cohost-broker-failed")

    async def _on_p2p_connect(self) -> None:
        """When a controller connects to our p2p server, surface its presence so
        the thumbnail gate (§6.4) opens — the controller is now watching."""
        self.controller_present = True

    # --- startup ------------------------------------------------------
    def start_os_subsystems(self) -> None:
        """Spawn mpv (via watchdog) + kiosk + discovery. No-ops degrade
        gracefully when a dependency is missing (e.g. on CI)."""
        if KioskGuard is not None:
            self.kiosk = KioskGuard(enabled=True)
            self.kiosk.engage()

        if MpvWatchdog is not None:
            mcfg = self.cfg.raw["mpv"]
            ipc = mcfg["ipc_pipe"] if sys.platform == "win32" else mcfg["ipc_socket"]
            wd = self.cfg.raw["watchdog"]
            self.watchdog = MpvWatchdog(
                mpv_path=mcfg.get("path", "mpv"), ipc_path=ipc,
                idle_image=self.cfg.get("idle_image"),
                hwdec=mcfg.get("hwdec", "auto-safe"),
                extra_args=mcfg.get("extra_args", []),
                check_interval_s=float(wd.get("check_interval_s", 1.0)),
                restart_grace_s=float(wd.get("restart_grace_s", 5.0)),
                on_restart=self._on_mpv_restart)
            try:
                self.mpv = self.watchdog.start()
                self._apply_idle_screen()
            except Exception as exc:
                log.error("mpv failed to start (running headless?): %s", exc)
                self._errors.append(f"mpv-start:{type(exc).__name__}")

        if Thumbnailer is not None and self.mpv is not None:
            tc = self.cfg.raw["thumbnail"]
            self.thumbnailer = Thumbnailer(
                self.mpv, max_width=int(tc.get("max_width", 320)),
                quality=int(tc.get("jpeg_quality", 70)))

        if DiscoveryResponder is not None and \
                self.cfg.get("discovery", "enabled", default=True):
            # §14: advertise the right coordinator. cohosted/p2p → this machine
            # is the coordinator (announce our own ip:8770); dedicated → point
            # at the configured/discovered broker.
            topo = self.decision.topology if self.decision else "dedicated"
            if topo in (topology_mod.COHOSTED, topology_mod.P2P):
                port = self.decision.listen_port or self.decision.port or 8770
                bh = f"{self.ip}:{port}"
            else:
                host = self.decision.host if self.decision else \
                    self.cfg.get("broker", "host")
                port = self.decision.port if self.decision else \
                    self.cfg.get("broker", "port")
                bh = f"{host}:{port}"
            self.discovery = DiscoveryResponder(
                psk=self.cfg.psk, device_id=self.device_id,
                device_name=self.device_name, ip=self.ip, broker_hint=bh,
                port=int(self.cfg.get("discovery", "udp_port", default=8772)),
                auth_mode=self.auth.mode, topology=topo,
                key_mode=self.auth.key_mode, device_key=self.auth.device_key,
                verify_keys=self.auth.verify_keys)
            self.discovery.start()

    def _apply_idle_screen(self) -> None:
        """Show placeholder image or black — never the desktop (§11)."""
        img = self.cfg.get("idle_image")
        if img and self.mpv is not None:
            self._mpv_sync("show_image", img)
        elif self.mpv is not None:
            self._mpv_sync("stop")  # mpv --idle/--force-window → black

    def _on_mpv_restart(self, ctl) -> None:
        """Watchdog handed us a fresh mpv — re-point and resume last task."""
        self.mpv = ctl
        if self.thumbnailer is not None:
            self.thumbnailer.controller = ctl
        log.warning("mpv restarted (#%s) — resuming last task",
                    getattr(self.watchdog, "restarts", "?"))
        if self.loop is not None:
            if self._restore_task and not self._restore_task.done():
                self._restore_task.cancel()
            self._restore_task = asyncio.run_coroutine_threadsafe(
                self._resume_last(), self.loop)
        else:
            self._apply_idle_screen()

    # --- §4 hello on (re)connect -------------------------------------
    async def _on_connect(self) -> None:
        await self.ws.send("hello", {
            "role": "player",
            "device_id": self.device_id,
            "device_name": self.device_name,
            "platform": "windows" if sys.platform == "win32" else "linux",
            "app_version": APP_VERSION,
            "ip": self.ip,
            "screen": self._screen(),
            # cache_cleanup_v1 / cache_inventory_v1 advertised ONLY now that the
            # live handlers + terminal-result emission exist (capability truth,
            # E0001): a controller must never send and silently time out.
            "capabilities": ["video", "image", "audio", "thumbnail",
                             "cache_cleanup_v1", "cache_inventory_v1",
                             "runtime_modes_v1", "music_shuffle_v1"],
            "group_id": self.group_id,
        })

    def _screen(self) -> Dict[str, int]:
        # mpv can report display geometry once a window exists; fall back to
        # 1080p when running headless / pre-window.
        if self.mpv is not None:
            w = self._mpv_sync("get_property_safe", "display-width")
            h = self._mpv_sync("get_property_safe", "display-height")
            if isinstance(w, int) and isinstance(h, int) and w > 0 and h > 0:
                return {"w": w, "h": h}
        return {"w": 1920, "h": 1080}

    def _on_cache_change(self) -> None:
        if self.loop is not None:
            self.loop.call_soon_threadsafe(self._cache_dirty.set)

    # --- §5 status loop ----------------------------------------------
    async def status_loop(self) -> None:
        interval = float(self.cfg.get("status_interval_s", default=1.5))
        while True:
            try:
                await self._send_status()
            except Exception:
                log.exception("status send failed")
            await asyncio.sleep(interval)

    async def _send_status(self) -> None:
        snap = await self._mpv("snapshot") or {}
        current = None
        item = self._current_item()
        if item is not None:
            current = {
                "item_id": item.get("item_id"),
                "name": item.get("name"),
                "position_ms": int(snap.get("position_ms", 0)),
                "duration_ms": int(snap.get("duration_ms",
                                    item.get("duration_ms", 0) or 0)),
            }
        await self.ws.send("status", {
            "device_id": self.device_id,
            # §5.1 / §5.2: identity field; without it the controller wall keeps
            # showing device_id after a remote configure_device rename.
            "device_name": self.device_name,
            "online": True,
            "group_id": self.group_id,
            "state": self._effective_state(snap),
            "runtime_mode": self.runtime_mode.current.value,
            "previous_active_mode": self.runtime_mode.previous_active.value,
            "music_playlist_id": (self.music_playlist or {}).get("playlist_id"),
            "music_playlist_revision": (self.music_playlist or {}).get("revision"),
            "music_playlist_size": len((self.music_playlist or {}).get("items", [])),
            "music_current_item_id": self.music_current_item_id,
            "music_shuffle_cycle": self.music_shuffle.cycle,
            "music_play_count": self.music_play_count,
            "current": current,
            "playlist_id": self.playlist.get("playlist_id") if self.playlist else None,
            # Per-replace identity; playlist_id itself may be reused.
            "push_id": self.playlist.get("push_id") if self.playlist else None,
            # §6.3a additive: position in the ordered active playlist + its
            # length (old controllers ignore unknown fields).
            "current_index": self.index if self.playlist else None,
            "playlist_count": len(self.playlist.get("items", [])) if self.playlist else 0,
            "loop_mode": resolve_loop_mode(self.playlist).value if self.playlist else None,
            "volume": int(snap.get("volume", self.volume) if snap else self.volume),
            "muted": bool(snap.get("muted", self.muted) if snap else self.muted),
            "audio_master": self.audio_master,
            "cache": self.downloader.cache_status(),
            # §26 lightweight summary (full per-item list is on-demand via §28).
            "cache_summary": self._cache_summary(),
            "capabilities": ["video", "image", "audio", "thumbnail",
                             "cache_cleanup_v1", "cache_inventory_v1",
                             "runtime_modes_v1", "music_shuffle_v1"],
            # §19 remote config: advertise what the safe patch can touch + the
            # current authoritative snapshot (revision for optimistic concurrency,
            # redacted values — never the psk). Old controllers ignore both.
            "config_capabilities": self._config_capabilities(),
            "config_snapshot": self._config_snapshot(),
            "clock_offset_ms": self.clock.offset_ms,
            "cpu": self._cpu_percent(),
            "errors": self._errors[-5:],
        })

    # --- §19 remote config: capabilities + redacted snapshot -----------
    def _config_capabilities(self) -> Dict[str, Any]:
        """What a controller may change and through which command. Lets the UI
        render the right editors and disable what a given player can't do."""
        return {
            "safe_fields": list(config_mod.SAFE_CONFIG_FIELDS),
            "transport_fields": list(config_mod.TRANSPORT_CONFIG_FIELDS),
            # high-risk paths use dedicated, separately-guarded commands rather
            # than the ordinary safe patch (§19.3/§19.5).
            "transport_configure": True,
            "rotate_device_key": True,
            "config_version": 1,
        }

    def _config_snapshot(self) -> Dict[str, Any]:
        """Authoritative view of this device's config for the controller.

        NEVER carries key material: the psk is reduced to a boolean
        `psk_configured` (redaction boundary, §19.5). `revision` is the
        optimistic-concurrency token controllers echo back as base_revision."""
        psk = self.cfg.psk
        psk_configured = bool(psk) and psk != config_mod.DEFAULT_PSK_PLACEHOLDER
        return {
            "revision": self.state.config_revision,
            "values": {
                "device_name": self.device_name,
                "group_id": self.group_id,
                "volume": self.volume,
                "muted": self.muted,
                # presence only — the value itself never leaves the device.
                "psk_configured": psk_configured,
            },
            # transport is a separate high-risk surface; expose non-secret
            # current wiring so the UI can show it without a rotate round-trip.
            "transport": {
                "broker_host": self.state.broker_host,
                "broker_port": self.state.broker_port,
                "use_wss": self.state.use_wss,
                "auto_discovery": self.state.broker_host is None,
            },
            "pending": {},
            "requires_restart": False,
        }

    def _effective_state(self, snap: Dict[str, Any]) -> str:
        # downloading takes visual priority only when nothing is playing
        if self.play_state in ("playing", "paused"):
            if snap.get("paused") and self.play_state == "playing":
                return "paused"
            return self.play_state
        if any(v.startswith("downloading") for v in
               self.downloader.cache_status().values()):
            return "downloading"
        return self.play_state if self.play_state in VALID_STATES else "idle"

    def _cpu_percent(self) -> int:
        try:
            import psutil  # optional
            return int(psutil.cpu_percent(interval=None))
        except Exception:
            return 0

    # --- inbound dispatch (§6, §9, §10) ------------------------------
    async def _on_message(self, type_: str, payload: Dict[str, Any],
                          env: Dict[str, Any]) -> None:
        handler = {
            "cache_prefetch": self._h_cache_prefetch,
            "playlist": self._h_playlist,
            "music_playlist": self._h_music_playlist,
            "set_runtime_mode": self._h_set_runtime_mode,
            "restore_runtime_mode": self._h_restore_runtime_mode,
            "prepare": self._h_prepare,
            "play_at": self._h_play_at,
            "pause": self._h_pause,
            "resume": self._h_resume,
            "stop": self._h_stop,
            "next": self._h_next,
            "prev": self._h_prev,
            "set_volume": self._h_set_volume,
            "set_mute": self._h_set_mute,
            "set_audio_master": self._h_set_audio_master,
            "assign_group": self._h_assign_group,
            "configure_device": self._h_configure_device,
            "transport_configure": self._h_transport_configure,
            "rotate_device_key": self._h_rotate_device_key,
            "debug_snapshot": self._h_debug_snapshot,
            "download_logs": self._h_download_logs,
            "cache_cleanup": self._h_cache_cleanup,
            "cache_inventory": self._h_cache_inventory,
            "resume_last": self._h_resume_last,
            "welcome": self._h_welcome,
        }.get(type_)
        if handler is None:
            return
        await handler(payload, env)
        # ack commands that carry a msg_id (§10)
        if type_ in ("prepare", "pause", "resume", "stop", "next", "prev",
                     "set_volume", "set_mute", "set_audio_master",
                     "assign_group", "configure_device", "cache_prefetch",
                     "playlist", "debug_snapshot", "download_logs"):
            await self._ack(env, True)

    async def _ack(self, env: Dict[str, Any], ok: bool, err: str = "") -> None:
        await self.ws.send("ack", {"ack_of": env.get("msg_id"), "ok": ok,
                                   "err": err})

    # --- §27/§28 cache cleanup + inventory (cache_cleanup_v1) ---------
    def _cleanup(self) -> "cache_cleanup.CacheCleanup":
        """Long-lived cleanup transaction (holds the idempotency journal)."""
        c = getattr(self, "_cleanup_obj", None)
        if c is None:
            backend = cache_live.LiveCacheBackend(self)
            c = cache_cleanup.CacheCleanup(backend, lock=self._cache_generation_lock)
            self._cleanup_obj = c  # type: ignore[attr-defined]
            self._cleanup_backend = backend  # type: ignore[attr-defined]
        return c

    async def _h_cache_cleanup(self, payload, env) -> None:
        """§27: async destructive op. NO optimistic generic ack — the player
        emits ONLY the terminal cache_cleanup_result (truthfulness, E0001)."""
        if not self._targets_me(payload):
            return
        request_id = payload.get("request_id")
        mode = payload.get("mode")
        dry_run = payload.get("dry_run", False)
        item_ids = payload.get("item_ids")
        selected_valid = (mode != "selected" or
                          isinstance(item_ids, list) and bool(item_ids) and
                          all(isinstance(i, str) and i for i in item_ids))
        expected_push_id = payload.get("expected_push_id")
        destructive_valid = (dry_run is True or
                             mode == "selected" and selected_valid and
                             isinstance(expected_push_id, str) and bool(expected_push_id))
        if (not isinstance(request_id, str) or not request_id or
                mode not in ("selected", "unreferenced") or
                not isinstance(dry_run, bool) or not selected_valid or
                not destructive_valid):
            return
        req = cache_cleanup.CleanupRequest(
            request_id=request_id,
            mode=mode,
            item_ids=item_ids,
            dry_run=dry_run,
            expected_push_id=expected_push_id,
            reason=str(payload.get("reason", "manual")),
            target=(f"device:{payload['device_id']}" if payload.get("device_id") else
                    f"group:{payload['group_id']}" if payload.get("group_id") else "all"),
        )
        # Scan/verify/delete off the event loop so the WS receive loop, heartbeat
        # and playback transitions never stall (design req. 10).
        result = await asyncio.to_thread(self._cleanup().run, req)
        result["device_id"] = self.device_id
        if not req.dry_run:
            self._last_cleanup = {  # type: ignore[attr-defined]
                "at": now_ms(),
                "error": "" if result.get("ok") else result.get("error", ""),
            }
            self._cache_dirty.set()  # commit changed the cache → refresh status
        await self.ws.send("cache_cleanup_result", result, to="controller")

    async def _h_cache_inventory(self, payload, env) -> None:
        """§28: on-demand full per-item inventory (not in periodic status)."""
        if not self._targets_me(payload):
            return
        items = await asyncio.to_thread(self._inventory_items)
        await self.ws.send("cache_inventory_result", {
            "request_id": str(payload.get("request_id", "")),
            "device_id": self.device_id,
            "items": items,
        }, to="controller")

    def _inventory_items(self) -> List[Dict[str, Any]]:
        backend = cache_live.LiveCacheBackend(self)
        snapshot = backend.build_snapshot()
        out: List[Dict[str, Any]] = []
        for it in backend.inventory():
            iid = it["item_id"]
            key = cache_live.content_key_of(it)
            reasons: List[str] = []
            kind, reason = snapshot.classify_item(iid)
            if reason is not None and reason != cache_refs.NOT_FOUND:
                reasons.append(reason)
            out.append({
                "item_id": iid,
                "content_key": key,
                "bytes": backend.size_of(key) if key else None,
                "state": "ready",
                "protection_reasons": reasons,
                "last_access_ms": 0,
            })
        return out

    def _cache_summary(self) -> Dict[str, Any]:
        """§26 lightweight summary for periodic status (no full item list)."""
        backend = cache_live.LiveCacheBackend(self)
        snapshot = backend.build_snapshot()
        ready_items = 0
        total_bytes = 0
        protected_items = 0
        reclaimable_items = 0
        reclaimable_bytes = 0
        for it in backend.inventory():
            iid = it["item_id"]
            key = cache_live.content_key_of(it)
            size = backend.size_of(key) if key else None
            ready_items += 1
            if size:
                total_bytes += size
            kind, reason = snapshot.classify_item(iid)
            if reason is not None and reason != cache_refs.NOT_FOUND:
                protected_items += 1
            else:
                reclaimable_items += 1
                if size:
                    reclaimable_bytes += size
        inflight = len(self.downloader.inflight_paths())
        last = getattr(self, "_last_cleanup", {"at": 0, "error": ""})
        return {
            "ready_items": ready_items,
            "total_bytes": total_bytes,
            "reclaimable_items": reclaimable_items,
            "reclaimable_bytes": reclaimable_bytes,
            "protected_items": protected_items,
            "inflight_items": inflight,
            "last_cleanup_at": last.get("at", 0),
            "last_cleanup_error": last.get("error", ""),
        }

    async def _h_welcome(self, payload, env) -> None:
        # broker may override our group assignment via snapshot; honor it if
        # explicitly present for this device.
        if payload.get("assigned") is False:
            self._errors.append("not-assigned")

    async def _diagnostic_text(self) -> str:
        snap = await self._mpv("snapshot") or {}
        cache = self.downloader.cache_status()
        playlist_id = self.playlist.get("playlist_id") if self.playlist else ""
        return "\n".join((
            f"device_id={self.device_id}",
            f"device_name={self.device_name}",
            f"group_id={self.group_id}",
            f"play_state={self._effective_state(snap)}",
            f"playlist_id={playlist_id}",
            f"playlist_index={self.index}",
            f"volume={self.volume}",
            f"muted={self.muted}",
            f"clock_offset_ms={self.clock.offset_ms}",
            f"cache={cache}",
            f"errors={self._errors[-20:]}",
        ))

    async def _h_debug_snapshot(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        await self.ws.send("diagnostic_status", {
            "device_id": self.device_id,
            "detail": await self._diagnostic_text(),
            "app_version": APP_VERSION,
        })

    async def _h_download_logs(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        text = await self._diagnostic_text()
        await self.ws.send("download_logs_result", {
            "device_id": self.device_id,
            "text": text[-65536:],
            "file_name": f"lan-media-wall-player-{self.device_id}.log",
        })

    # --- §6.2 cache_prefetch -----------------------------------------
    async def _h_cache_prefetch(self, payload, env) -> None:
        items = payload.get("items", [])
        if items:
            self.downloader.prefetch(items)

    # --- runtime modes / independent music playlist -------------------
    async def _send_music_playlist_result(self, request_id: str, ok: bool,
                                          error: str = "") -> None:
        await self.ws.send("music_playlist_result", {
            "request_id": request_id,
            "device_id": self.device_id,
            "ok": ok,
            "error": error,
            "playlist_id": (self.music_playlist or {}).get("playlist_id"),
            "revision": (self.music_playlist or {}).get("revision"),
        }, to="controller")

    async def _h_music_playlist(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        request_id = str(payload.get("request_id", ""))
        parsed = MusicPlaylist.from_payload(payload)
        if parsed is None:
            await self._send_music_playlist_result(request_id, False,
                                                   "invalid_music_playlist")
            return
        normalized = {
            "playlist_id": parsed.playlist_id,
            "revision": parsed.revision,
            "items": parsed.items,
        }
        current = self.music_playlist
        if current is not None:
            current_revision = int(current.get("revision", -1))
            if parsed.revision < current_revision:
                await self._send_music_playlist_result(request_id, False,
                                                       "stale_revision")
                return
            if parsed.revision == current_revision and current != normalized:
                await self._send_music_playlist_result(request_id, False,
                                                       "revision_conflict")
                return
        self.music_playlist = normalized
        self.state.set_music_playlist(normalized)
        self.music_shuffle.reset()
        self.music_failures.clear()
        self.music_current_item_id = None
        self.downloader.prefetch(parsed.items)
        if self.runtime_mode.current is PlaybackMode.MUSIC:
            self.mode_generation += 1
            await self._mpv("stop")
            await self._play_next_music(self.mode_generation)
        await self._send_music_playlist_result(request_id, True)

    async def _send_runtime_mode_result(self, request_id: str, ok: bool,
                                        error: str = "") -> None:
        await self.ws.send("runtime_mode_result", {
            "request_id": request_id,
            "device_id": self.device_id,
            "ok": ok,
            "error": error,
            "runtime_mode": self.runtime_mode.current.value,
            "previous_active_mode": self.runtime_mode.previous_active.value,
        }, to="controller")

    async def _h_set_runtime_mode(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        request_id = str(payload.get("request_id", ""))
        mode = PlaybackMode.parse(payload.get("mode"))
        if mode is None:
            await self._send_runtime_mode_result(request_id, False,
                                                 "invalid_runtime_mode")
            return
        await self._apply_runtime_mode(mode)
        await self._send_runtime_mode_result(request_id, True)

    async def _h_restore_runtime_mode(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        request_id = str(payload.get("request_id", ""))
        target = self.runtime_mode.previous_active
        if target is PlaybackMode.STANDBY:
            target = PlaybackMode.VISUAL
        await self._apply_runtime_mode(target)
        await self._send_runtime_mode_result(request_id, True)

    async def _apply_runtime_mode(self, mode: PlaybackMode) -> None:
        self.mode_generation += 1
        generation = self.mode_generation
        self._cancel_session_tasks()
        await self._mpv("stop")
        self.play_state = "idle"
        self.music_current_item_id = None
        self.runtime_mode.set_mode(mode)
        self.state.set_runtime_mode(
            self.runtime_mode.current.value,
            self.runtime_mode.previous_active.value,
        )
        if mode is PlaybackMode.MUSIC:
            await self._play_next_music(generation)
        elif mode is PlaybackMode.VISUAL:
            await self._resume_last(generation)
        else:
            self._apply_idle_screen()

    async def _play_next_music(self, generation: int) -> None:
        if generation != self.mode_generation or \
                self.runtime_mode.current is not PlaybackMode.MUSIC:
            return
        items = (self.music_playlist or {}).get("items", [])
        by_id = {str(item.get("item_id")): item for item in items
                 if item.get("item_id")}
        candidates = [item_id for item_id in by_id
                      if item_id not in self.music_failures]
        item_id = self.music_shuffle.next(candidates)
        if item_id is None:
            self.music_current_item_id = None
            self.play_state = "idle" if not items else "error"
            error = "music_playlist_empty" if not items else "music_all_unavailable"
            if not self._errors or self._errors[-1] != error:
                self._errors.append(error)
            return
        item = by_id[item_id]
        path = self.downloader.ready_path(item_id) or item.get("url")
        if not path:
            self.music_failures.add(item_id)
            await self._play_next_music(generation)
            return
        self.music_current_item_id = item_id
        self.music_play_count += 1
        self.music_started_monotonic = time.monotonic()
        await self._mpv("loadfile", str(path), "replace")
        await self._mpv("set_loop_file", False)
        await self._mpv("set_pause", False)
        if generation == self.mode_generation and \
                self.runtime_mode.current is PlaybackMode.MUSIC:
            self.play_state = "playing"

    # --- §6.3 playlist -----------------------------------------------
    async def _h_playlist(self, payload, env) -> None:
        with self._cache_generation_lock:
            mode = playlist_ops.normalize_mode(payload.get("mode"))
            items = payload.get("items", []) or []
            if mode == playlist_ops.APPEND:
                # §6.3a merge onto the tail, de-duped by item_id; existing indices
                # never shift so current_index stays valid. Empty append = no-op.
                if not items:
                    return
                if not self.playlist:
                    # nothing active to append to → treat as a fresh replace
                    self.playlist = dict(payload)
                    self.index = 0
                else:
                    merged = playlist_ops.merge_append(
                        self.playlist.get("items", []), items)
                    self.playlist = {**self.playlist, "items": merged}
                self.state.store_playlist(self.playlist)
                self.downloader.prefetch(items)
                return
            # replace (default). An empty replace is the CLEAR signal (§6.3a):
            # clear active playlist + current state, enter idle/black, but never
            # delete cached media inventory.
            if not items:
                await self._clear_active_playlist(
                    str(payload.get("playlist_id") or ""), lock_held=True)
                return
            self._cancel_session_tasks()
            self.playlist = dict(payload)
            self.index = 0
            self.state.store_playlist(self.playlist)
            self.downloader.prefetch(items)
            # sync=false → broker drives single-box play_at=now separately; we just
            # store. sync=true → wait for prepare/play_at.

    async def _clear_active_playlist(self, playlist_id: str,
                                     *, lock_held: bool = False) -> None:
        """§6.3a empty-replace CLEAR: stop playback, drop the active playlist and
        current index/task, show the idle black/placeholder — cache inventory on
        disk is deliberately left intact."""
        active_playlist_id = (self.playlist or {}).get("playlist_id")
        self._cancel_session_tasks()
        if self.runtime_mode.current is PlaybackMode.VISUAL:
            await self._mpv("stop")
            self._apply_idle_screen()
            self.play_state = "idle"
        for pid in {active_playlist_id, playlist_id} - {None, ""}:
            self.state.delete_playlist(str(pid))
        with self._cache_generation_lock:
            self.playlist = None
            self.index = 0
            self._persist_last_task(None, 0, 0)

    # --- §9.1 prepare -------------------------------------------------
    async def _h_prepare(self, payload, env) -> None:
        if self.runtime_mode.current is not PlaybackMode.VISUAL:
            return
        if self._barrier_task and not self._barrier_task.done():
            self._barrier_task.cancel()
        pid = payload.get("playlist_id")
        push_id = payload.get("push_id")
        prepare_id = payload.get("prepare_id")
        group_id = payload.get("group_id")
        start_index = int(payload.get("start_index", 0))
        seek_ms = int(payload.get("seek_ms", 0))
        # §21 预缓存栅栏:控制端置 prefetch:true 表示"缓存好再回 ready"。此时若尚未缓存,
        # 不立刻回 ready:false,而是后台等下载+校验完成再回 ready:true,让全员统一从头起播。
        prefetch_barrier = bool(payload.get("prefetch", False))
        barrier_timeout_ms = int(payload.get("barrier_timeout_ms", 120000))
        pl = self._resolve_playlist(pid)
        if not pl or not push_id or pl.get("push_id") != push_id:
            return
        ready = False
        self._cancel_dwell()  # §6.3: a new session voids any pending dwell
        if pl is not None:
            items = pl.get("items", [])
            if 0 <= start_index < len(items):
                item = items[start_index]
                with self._cache_generation_lock:
                    self.playlist = pl
                    self.index = start_index
                if self.downloader.is_ready(item["item_id"]):
                    path = str(self.downloader.ready_path(item["item_id"]))
                    # §6.1: an image has no decoder to prime — it's shown at the
                    # sync instant (play_at). A video primes paused so play_at
                    # just flips pause off.
                    if item.get("type") != "image":
                        await self._mpv("play_paused", path, seek_ms=seek_ms)
                    self.play_state = "buffering"
                    ready = True
                elif prefetch_barrier:
                    # §21 栅栏:后台等缓存完成再回 ready,不阻塞事件循环。保留 task 引用,
                    # 否则 asyncio 可能在其运行前将其回收(fire-and-forget 陷阱)。
                    self.downloader.prefetch([item])
                    self._barrier_task = asyncio.ensure_future(
                        self._await_cache_then_ready(
                            pid, prepare_id, group_id, item, seek_ms,
                            barrier_timeout_ms))
                    return
                else:
                    # 非栅栏路径:not cached yet — kick a fetch; report not-ready
                    self.downloader.prefetch([item])
        await self.ws.send("ready", {
            "device_id": self.device_id,
            "playlist_id": pid,
            "prepare_id": prepare_id,
            "group_id": group_id,
            "ready": ready,
        })

    async def _await_cache_then_ready(
            self, pid, prepare_id, group_id, item, seek_ms: int,
            timeout_ms: int) -> None:
        """§21 预缓存栅栏:轮询该 item 的缓存态,ready 后 prime 并回 ready:true;
        超时则回 ready:false,让控制端按"已就绪者"降级起播(不无限等)。"""
        deadline = self._loop_time() + timeout_ms / 1000.0
        item_id = item["item_id"]
        while self._loop_time() < deadline:
            if self.downloader.is_ready(item_id):
                path = str(self.downloader.ready_path(item_id))
                if item.get("type") != "image":
                    await self._mpv("play_paused", path, seek_ms=seek_ms)
                self.play_state = "buffering"
                await self.ws.send("ready", {
                    "device_id": self.device_id,
                    "playlist_id": pid,
                    "prepare_id": prepare_id,
                    "group_id": group_id,
                    "ready": True,
                })
                return
            await asyncio.sleep(0.5)
        # 超时未就绪:如实上报,交给控制端/broker 决定降级。
        await self.ws.send("ready", {
            "device_id": self.device_id,
            "playlist_id": pid,
            "prepare_id": prepare_id,
            "group_id": group_id,
            "ready": False,
        })

    @staticmethod
    def _loop_time() -> float:
        return asyncio.get_event_loop().time()

    # --- §9.2 play_at (the sync-critical path) -----------------------
    async def _h_play_at(self, payload, env) -> None:
        if self.runtime_mode.current is not PlaybackMode.VISUAL:
            return
        pid = payload.get("playlist_id")
        push_id = payload.get("push_id")
        start_index = int(payload.get("start_index", self.index))
        seek_ms = int(payload.get("seek_ms", 0))
        play_at = int(payload.get("play_at", 0))
        pl = self._resolve_playlist(pid)
        if not pl or not push_id or pl.get("push_id") != push_id:
            return
        items = pl.get("items", [])
        if not (0 <= start_index < len(items)):
            return
        with self._cache_generation_lock:
            self.playlist = pl
            self.index = start_index
        item = items[start_index]
        path = self.downloader.ready_path(item["item_id"])
        if path is None:
            # last-ditch: play from URL if not cached (degrade, don't go black)
            path = item.get("url")
        if path is None:
            self._errors.append("play_at-no-source")
            return
        # cancel any pending scheduled start / image dwell
        if self._play_task and not self._play_task.done():
            self._play_task.cancel()
        self._cancel_dwell()
        self._persist_last_task(pid, start_index, seek_ms)
        self._play_task = asyncio.create_task(
            self._scheduled_start(str(path), seek_ms, play_at, item))

    async def _scheduled_start(self, path: str, seek_ms: int, play_at: int,
                               item: Dict[str, Any]) -> None:
        """§8.2 fold play_at (master clock) → local target, then start. A video
        is primed paused and unpaused at the instant; an image is shown at the
        instant and its dwell armed so the carousel advances (§6.3)."""
        if item.get("type") == "image":
            await self._await_local(self.clock.to_local(play_at))
            if self.runtime_mode.current is not PlaybackMode.VISUAL:
                return
            await self._mpv("show_image", path)
            self.play_state = "playing"
            self._arm_dwell(item)
            return
        # video: ensure file is loaded & paused at seek (idempotent if prepare
        # did it), then unpause at the exact local instant.
        await self._mpv("play_paused", path, seek_ms=seek_ms)
        # §6.3 ONE: seamless in-decoder repeat; other modes advance on eof.
        await self._mpv("set_loop_file",
                        resolve_loop_mode(self.playlist) is LoopMode.ONE)
        await self._await_local(self.clock.to_local(play_at))
        if self.runtime_mode.current is not PlaybackMode.VISUAL:
            return
        await self._mpv("set_pause", False)
        self.play_state = "playing"
        log.info("play_at fired: now=%d offset=%d", now_ms(), self.clock.offset_ms)

    async def _await_local(self, local_target: int) -> None:
        """Busy-wait the final stretch for sub-100ms accuracy; coarse-sleep
        first (§8.2)."""
        while True:
            remaining = local_target - now_ms()
            if remaining <= 0:
                break
            await asyncio.sleep(min(remaining / 1000.0, 0.05) if remaining > 60
                                else 0.001)
            if remaining <= 8:
                # tight spin for the last few ms
                while local_target - now_ms() > 0:
                    pass
                break

    # --- §9.3 controls -----------------------------------------------
    async def _h_pause(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        if self._resume_task and not self._resume_task.done():
            self._resume_task.cancel()
        await self._mpv("set_pause", True)
        self.play_state = "paused"

    async def _h_resume(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        if self._resume_task and not self._resume_task.done():
            self._resume_task.cancel()
        play_at = payload.get("play_at")
        if play_at:
            self._resume_task = asyncio.create_task(
                self._scheduled_resume(self.clock.to_local(int(play_at))))
            return
        await self._mpv("set_pause", False)
        self.play_state = "playing"

    async def _scheduled_resume(self, local_target: int) -> None:
        await self._await_local(local_target)
        await self._mpv("set_pause", False)
        self.play_state = "playing"

    def _cancel_session_tasks(self) -> None:
        current = asyncio.current_task()
        for task in (self._play_task, self._barrier_task, self._resume_task,
                     self._restore_task):
            if task is not None and task is not current and not task.done():
                task.cancel()
        self._cancel_dwell()

    async def _h_stop(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        self._cancel_session_tasks()
        await self._mpv("stop")
        self._apply_idle_screen()
        self.play_state = "idle"
        self._persist_last_task(None, 0, 0)

    async def _h_next(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        await self._advance(+1, explicit=True)

    async def _h_prev(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        await self._advance(-1, explicit=True)

    async def _advance(self, delta: int, explicit: bool = False) -> None:
        """§6.3 progression. `explicit` distinguishes a user prev/next from an
        automatic EOF/dwell completion. LoopMode:
          - NONE: completion holds; explicit prev/next clamps at the ends.
          - ALL : both wrap around the whole list.
          - ONE : completion repeats the current item (seamless, no move);
                  explicit prev/next still navigates with wrap.
        """
        if self.runtime_mode.current is PlaybackMode.MUSIC:
            await self._play_next_music(self.mode_generation)
            return
        if self.runtime_mode.current is not PlaybackMode.VISUAL or not self.playlist:
            return
        items = self.playlist.get("items", [])
        if not items:
            return
        self._cancel_dwell()  # §6.3: never let dwell timers stack
        mode = resolve_loop_mode(self.playlist)
        # ONE, on automatic completion, re-shows the current item seamlessly.
        if mode is LoopMode.ONE and not explicit:
            new_index = self.index
        else:
            wrap = mode is LoopMode.ALL or (mode is LoopMode.ONE and explicit)
            new_index = self.index + delta
            if new_index < 0 or new_index >= len(items):
                if wrap:
                    new_index %= len(items)
                else:
                    return  # NONE clamps at the boundary
        with self._cache_generation_lock:
            self.index = new_index
        item = items[new_index]
        path = self.downloader.ready_path(item["item_id"]) or item.get("url")
        if not path:
            return
        # §6.1: an image is shown + its dwell armed; a video is loaded and the
        # eof watch loop auto-advances it on end.
        if item.get("type") == "image":
            await self._mpv("show_image", str(path))
            self.play_state = "playing"
            self._arm_dwell(item)
        else:
            await self._mpv("loadfile", str(path), "replace")
            # §6.3 ONE: let mpv loop the file inside its own decoder (seamless,
            # no reload/seam, single decoder). Other modes advance on eof.
            await self._mpv("set_loop_file", mode is LoopMode.ONE)
            await self._mpv("set_pause", False)
            self.play_state = "playing"
        self._persist_last_task(self.playlist.get("playlist_id"),
                                new_index, 0)

    # --- §6.3 automatic progression (image dwell + video eof) --------
    def _cancel_dwell(self) -> None:
        if self._dwell_task and not self._dwell_task.done():
            self._dwell_task.cancel()
        self._dwell_task = None

    def _arm_dwell(self, item: Dict[str, Any]) -> None:
        """Hold the current image for its duration_ms (default
        DEFAULT_IMAGE_DWELL_MS) then step forward (§6.3)."""
        self._cancel_dwell()
        dwell = item.get("duration_ms") or DEFAULT_IMAGE_DWELL_MS
        self._dwell_task = asyncio.create_task(self._dwell_then_advance(int(dwell)))

    async def _dwell_then_advance(self, dwell_ms: int) -> None:
        try:
            await asyncio.sleep(max(0, dwell_ms) / 1000.0)
        except asyncio.CancelledError:
            return
        if self.runtime_mode.current is PlaybackMode.VISUAL:
            await self._advance(+1)

    def _music_snapshot_failed(self, snap: Dict[str, Any],
                               now: Optional[float] = None) -> bool:
        """Classify MPV load failure without treating a normal track EOF as bad."""
        now = time.monotonic() if now is None else now
        duration = int(snap.get("duration_ms", 0) or 0)
        position = int(snap.get("position_ms", 0) or 0)
        immediate_eof = bool(snap.get("eof")) and duration <= 0 and position <= 500
        stalled_idle = not bool(snap.get("eof")) and bool(snap.get("idle")) and \
            duration <= 0 and position <= 500 and \
            now - self.music_started_monotonic >= 2.0
        return immediate_eof or stalled_idle

    async def eof_watch_loop(self) -> None:
        """§6.3: a non-looping video that reaches its end has no external nudge
        to advance — mpv holds the last frame (--keep-open=yes). Poll
        `eof-reached` while a video plays and step forward once when it flips.
        Images use --image-display-duration=inf and never reach eof, so they're
        driven solely by the dwell timer."""
        seen_eof = False
        while True:
            await asyncio.sleep(0.5)
            if self.play_state != "playing" or self.mpv is None:
                seen_eof = False
                continue
            item = self._current_item()
            if item is None or item.get("type") == "image":
                seen_eof = False
                continue
            snap = await self._mpv("snapshot") or {}
            if self.runtime_mode.current is PlaybackMode.MUSIC and \
                    self._music_snapshot_failed(snap):
                if self.music_current_item_id:
                    self.music_failures.add(self.music_current_item_id)
                    error = f"music_load_failed:{self.music_current_item_id}"
                    if not self._errors or self._errors[-1] != error:
                        self._errors.append(error)
                seen_eof = False
                await self._advance(+1)
                continue
            if snap.get("eof"):
                if not seen_eof:
                    seen_eof = True
                    await self._advance(+1)
            else:
                seen_eof = False

    async def _h_set_volume(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        self.volume = int(payload.get("volume", self.volume))
        await self._mpv("set_volume", self.volume)

    async def _h_set_mute(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        self.muted = bool(payload.get("muted", self.muted))
        await self._mpv("set_mute", self.muted)

    async def _h_set_audio_master(self, payload, env) -> None:
        # §9.3: device_ids lists who should output sound; others mute. Default
        # (no list / empty) = everyone outputs.
        ids = payload.get("device_ids")
        if ids is None:
            self.audio_master = True
        else:
            self.audio_master = self.device_id in ids
        self.muted = not self.audio_master
        await self._mpv("set_mute", self.muted)

    async def _h_assign_group(self, payload, env) -> None:
        if payload.get("device_id") != self.device_id:
            return
        gid = payload.get("group_id")
        if gid:
            self.group_id = gid
            self.state.set_group_id(gid)

    # --- §19 configure_device ----------------------------------------
    async def _h_configure_device(self, payload, env) -> None:
        """盒子配置(§19):改显示名 / 设组 / 设音量 / 连接(broker)。仅对本机
        device_id 生效,缺省字段不动。改动持久化,重启后保留。连接字段变更后
        写盘并重建 transport;psk 要求入站帧已签名(sig 非空)。"""
        if payload.get("device_id") != self.device_id:
            return
        # §19: configure_device is always a safe patch. Transport and secret
        # fields are rejected regardless of whether an older caller supplies a
        # request_id; they must use their dedicated command paths below.
        request_id = payload.get("request_id")
        rejected: List[Dict[str, Any]] = []
        applied: Dict[str, Any] = {}
        base = payload.get("base_revision")
        if (request_id is not None and isinstance(base, (int, float)) and
                int(base) != self.state.config_revision):
            # stale base → lost-update conflict: apply nothing, return current rev.
            await self.ws.send("config_patch_result", {
                "request_id": request_id, "device_id": self.device_id,
                "ok": False, "conflict": True, "revision": self.state.config_revision,
                "applied": {}, "rejected": [{"field": "_revision",
                                             "reason": "conflict"}],
                "pending": {}, "requires_restart": False}, to="controller")
            return
        for key in payload:
            if key in ("device_id", "request_id", "base_revision"):
                continue
            kind = config_mod.classify_config_field(key)
            if kind != "safe":
                rejected.append({"field": key, "reason": {
                    "transport": config_mod.REJECT_HIGH_RISK_TRANSPORT,
                    "secret": config_mod.REJECT_HIGH_RISK_SECRET,
                    "unknown": config_mod.REJECT_UNKNOWN_FIELD}[kind]})
        name = payload.get("device_name")
        name_dirty = False
        if isinstance(name, str) and name.strip():
            next_name = name.strip()
            if next_name != self.device_name:
                self.device_name = next_name
                self.state.set_device_name(self.device_name)
                if self.discovery is not None:
                    self.discovery.update_name(self.device_name)
                name_dirty = True
                applied["device_name"] = self.device_name
        gid = payload.get("group_id")
        if isinstance(gid, str) and gid and gid != self.group_id:
            self.group_id = gid
            self.state.set_group_id(gid)
            applied["group_id"] = gid
        vol = payload.get("volume")
        if isinstance(vol, (int, float)):
            next_volume = max(0, min(100, int(vol)))
            if next_volume != self.volume:
                self.volume = next_volume
                await self._mpv("set_volume", self.volume)
                self.state.set_volume(self.volume)
                applied["volume"] = self.volume
        muted = payload.get("muted")
        if isinstance(muted, bool) and muted != self.muted:
            self.muted = muted
            await self._mpv("set_mute", self.muted)
            self.state.set_muted(self.muted)
            applied["muted"] = self.muted

        # `configure_device` remains the safe, low-risk path for every caller.
        # Connection wiring and secrets are only accepted by the dedicated
        # transport_configure and rotate_device_key handlers below.
        if name_dirty:
            try:
                await self._send_status()
            except Exception:
                pass
            log.info("configure_device name=%s", self.device_name)
        if request_id is not None:
            # bump the monotonic revision only when a value actually changed; a
            # no-op patch leaves it untouched. ok=True means nothing was rejected
            # (a pure no-op with no rejections is still a success).
            revision = (self.state.bump_config_revision() if applied
                        else self.state.config_revision)
            await self.ws.send("config_patch_result", {
                "request_id": request_id, "device_id": self.device_id,
                "ok": not rejected, "conflict": False, "revision": revision,
                "applied": applied, "rejected": rejected,
                "pending": {}, "requires_restart": False}, to="controller")

    # --- §19.3 transport_configure (high-risk broker wiring) ----------
    async def _h_transport_configure(self, payload, env) -> None:
        """Dedicated high-risk path for broker_host/port/use_wss (§19.3). Kept
        OUT of the safe configure_device patch: it writes state, re-overlays cfg
        and rebuilds the live transport. An empty broker_host clears the override
        and restores auto-discovery/P2P. Emits config_patch_result as its
        terminal ack (never a plain ok)."""
        if payload.get("device_id") != self.device_id:
            return
        request_id = payload.get("request_id")
        host = payload.get("broker_host")
        if not isinstance(host, str):
            await self.ws.send("config_patch_result", {
                "request_id": request_id, "device_id": self.device_id,
                "ok": False, "revision": self.state.config_revision, "applied": {},
                "rejected": [{"field": "broker_host",
                              "reason": config_mod.REJECT_INVALID_VALUE}],
                "pending": {}, "requires_restart": False}, to="controller")
            return
        host_s = host.strip()
        if not host_s:
            self.state.clear_broker()
            # apply_state_transport is also the canonical inverse overlay: it
            # restores the baseline topology rather than leaving a stale broker
            # config in memory after an explicit clear.
            config_mod.apply_state_transport(self.cfg, self.state)
            self.cfg.raw.setdefault("topology", {})["auto"] = True
            applied = {"broker_host": "", "auto_discovery": True}
        else:
            port = payload.get("broker_port")
            port_i = int(port) if isinstance(port, (int, float)) else None
            use_wss = payload.get("use_wss")
            use_wss_b = bool(use_wss) if isinstance(use_wss, bool) else None
            self.state.set_broker(host=host_s, port=port_i, use_wss=use_wss_b)
            config_mod.apply_state_transport(self.cfg, self.state)
            applied = {"broker_host": host_s, "broker_port": self.state.broker_port,
                       "use_wss": self.state.use_wss}
        revision = self.state.bump_config_revision()
        asyncio.create_task(self._rebuild_transport())
        await self.ws.send("config_patch_result", {
            "request_id": request_id, "device_id": self.device_id,
            "ok": True, "revision": revision,
            "applied": applied, "rejected": [],
            "pending": {"transport": "reconnecting"}, "requires_restart": False},
            to="controller")

    # --- §19.5 rotate_device_key (secret material, signed-frame only) --
    async def _h_rotate_device_key(self, payload, env) -> None:
        """Dedicated path for the pre-shared key (§19.5). Only a SIGNED inbound
        frame may rotate the secret; the result NEVER echoes key material back —
        only a psk_configured flag. Refreshes AuthState and rebuilds transport so
        the new key takes effect without a restart."""
        if payload.get("device_id") != self.device_id:
            return
        request_id = payload.get("request_id")
        sig = env.get("sig") if isinstance(env, dict) else None
        if not sig:
            await self.ws.send("config_patch_result", {
                "request_id": request_id, "device_id": self.device_id,
                "ok": False, "revision": self.state.config_revision, "applied": {},
                "rejected": [{"field": "psk",
                              "reason": config_mod.REJECT_UNSIGNED_FRAME}],
                "pending": {}, "requires_restart": False}, to="controller")
            return
        psk = payload.get("psk")
        if not isinstance(psk, str) or not psk.strip():
            await self.ws.send("config_patch_result", {
                "request_id": request_id, "device_id": self.device_id,
                "ok": False, "revision": self.state.config_revision, "applied": {},
                "rejected": [{"field": "psk",
                              "reason": config_mod.REJECT_INVALID_VALUE}],
                "pending": {}, "requires_restart": False}, to="controller")
            return
        self.state.set_psk(psk.strip())
        config_mod.apply_state_transport(self.cfg, self.state)
        revision = self.state.bump_config_revision()
        try:
            self.auth.psk = self.cfg.psk  # type: ignore[attr-defined]
        except Exception:
            pass
        asyncio.create_task(self._rebuild_transport())
        await self.ws.send("config_patch_result", {
            "request_id": request_id, "device_id": self.device_id,
            "ok": True, "revision": revision,
            "applied": {"psk_configured": True}, "rejected": [],
            "pending": {}, "requires_restart": False}, to="controller")

    async def _rebuild_transport(self) -> None:
        """Stop the live WS/discovery link and re-bootstrap from current cfg.

        status/thumbnail/kiosk loops keep running; only the coordinator link
        is replaced so a remote broker_host change takes effect without a
        process restart.
        """
        async with self._transport_rebuild_lock:
            old_ws = self.ws
            old_ws_task = self._ws_task
            try:
                if self.discovery is not None:
                    try:
                        self.discovery.stop()
                    except Exception:
                        pass
                    self.discovery = None
                if old_ws is not None:
                    try:
                        await old_ws.stop()
                    except Exception:
                        pass
                if old_ws_task is not None and not old_ws_task.done():
                    old_ws_task.cancel()
                    try:
                        await old_ws_task
                    except (asyncio.CancelledError, Exception):
                        pass
                self.ws = None
                self._ws_task = None
                self.controller_present = bool(
                    self.cfg.get("thumbnail", "always_collect", default=False))
                self.decision = await asyncio.to_thread(self._discover_decision)
                self.ws = self._build_transport(self.decision)
                # refresh discovery advertisement for the new topology
                self._restart_discovery_only()
                self._ws_task = asyncio.create_task(self.ws.run(), name="ws")
            except Exception as exc:
                log.exception("transport rebuild failed: %s", exc)
                self._errors.append(f"transport_rebuild:{type(exc).__name__}")

    def _restart_discovery_only(self) -> None:
        """Re-bind DiscoveryResponder after a transport rebuild (§14)."""
        if DiscoveryResponder is None:
            return
        if not self.cfg.get("discovery", "enabled", default=True):
            return
        decision = self.decision
        topo = decision.topology if decision else "dedicated"
        if decision is not None and topo in (topology_mod.COHOSTED, topology_mod.P2P):
            port = decision.listen_port or decision.port or 8770
            bh = f"{self.ip}:{port}"
        else:
            host = decision.host if decision is not None else \
                self.cfg.get("broker", "host")
            port = decision.port if decision is not None else \
                self.cfg.get("broker", "port")
            bh = f"{host}:{port}"
        self.discovery = DiscoveryResponder(
            psk=self.cfg.psk, device_id=self.device_id,
            device_name=self.device_name, ip=self.ip, broker_hint=bh,
            port=int(self.cfg.get("discovery", "udp_port", default=8772)),
            auth_mode=self.auth.mode, topology=topo,
            key_mode=self.auth.key_mode, device_key=self.auth.device_key,
            verify_keys=self.auth.verify_keys)
        self.discovery.start()

    async def _h_resume_last(self, payload, env) -> None:
        await self._resume_last()

    # --- helpers ------------------------------------------------------
    def _targets_me(self, payload: Dict[str, Any]) -> bool:
        """A group/single command applies to us if it names our device_id, our
        group_id, or neither (broadcast handled by broker routing)."""
        dev = payload.get("device_id")
        grp = payload.get("group_id")
        if dev is not None:
            return dev == self.device_id
        if grp is not None:
            return grp == self.group_id
        return True

    def _resolve_playlist(self, pid: Optional[str]) -> Optional[Dict[str, Any]]:
        if self.playlist and self.playlist.get("playlist_id") == pid:
            return self.playlist
        if pid and pid in self.state.playlists:
            return self.state.playlists[pid]
        return None

    def _current_item(self) -> Optional[Dict[str, Any]]:
        if self.runtime_mode.current is PlaybackMode.STANDBY:
            return None
        if self.runtime_mode.current is PlaybackMode.MUSIC:
            for item in (self.music_playlist or {}).get("items", []):
                if item.get("item_id") == self.music_current_item_id:
                    return item
            return None
        if not self.playlist:
            return None
        items = self.playlist.get("items", [])
        if 0 <= self.index < len(items):
            return items[self.index]
        return None

    def _persist_last_task(self, pid: Optional[str], index: int,
                           seek_ms: int) -> None:
        if pid is None:
            self.state.set_last_task(None)
        else:
            self.state.set_last_task({
                "playlist_id": pid, "index": index, "seek_ms": seek_ms,
                "volume": self.volume, "muted": self.muted})

    async def _resume_last(self, generation: Optional[int] = None) -> None:
        """§10/§11: after a crash/reboot, return to the persisted runtime mode."""
        generation = self.mode_generation if generation is None else generation
        if generation != self.mode_generation:
            return
        if self.runtime_mode.current is PlaybackMode.STANDBY:
            self.play_state = "idle"
            self._apply_idle_screen()
            return
        if self.runtime_mode.current is PlaybackMode.MUSIC:
            await self._play_next_music(self.mode_generation)
            return
        task = self.state.last_task
        if not task:
            self._apply_idle_screen()
            return
        pl = self._resolve_playlist(task.get("playlist_id"))
        if pl is None:
            self._apply_idle_screen()
            return
        items = pl.get("items", [])
        idx = int(task.get("index", 0))
        if not (0 <= idx < len(items)):
            self._apply_idle_screen()
            return
        with self._cache_generation_lock:
            self.playlist = pl
            self.index = idx
        item = items[idx]
        path = self.downloader.ready_path(item["item_id"]) or item.get("url")
        if not path:
            self._apply_idle_screen()
            return
        self._cancel_dwell()
        await self._mpv("set_volume", int(task.get("volume", self.volume)))
        if generation != self.mode_generation or \
                self.runtime_mode.current is not PlaybackMode.VISUAL:
            return
        await self._mpv("set_mute", bool(task.get("muted", self.muted)))
        if generation != self.mode_generation or \
                self.runtime_mode.current is not PlaybackMode.VISUAL:
            return
        if item.get("type") == "image":
            await self._mpv("show_image", str(path))
            if generation != self.mode_generation or \
                    self.runtime_mode.current is not PlaybackMode.VISUAL:
                return
            self.play_state = "playing"
            self._arm_dwell(item)
            return
        await self._mpv("loadfile", str(path), "replace")
        if generation != self.mode_generation or \
                self.runtime_mode.current is not PlaybackMode.VISUAL:
            return
        await self._mpv("set_loop_file",
                        resolve_loop_mode(self.playlist) is LoopMode.ONE)
        if generation != self.mode_generation or \
                self.runtime_mode.current is not PlaybackMode.VISUAL:
            return
        await self._mpv("seek_abs_ms", int(task.get("seek_ms", 0)))
        if generation != self.mode_generation or \
                self.runtime_mode.current is not PlaybackMode.VISUAL:
            return
        await self._mpv("set_pause", False)
        if generation != self.mode_generation or \
                self.runtime_mode.current is not PlaybackMode.VISUAL:
            return
        self.play_state = "playing"

    # --- §6.4 thumbnail loop -----------------------------------------
    async def thumbnail_loop(self) -> None:
        tc = self.cfg.raw["thumbnail"]
        if not tc.get("enabled", True) or self.thumbnailer is None:
            return
        interval = float(tc.get("interval_s", 5))
        always = bool(tc.get("always_collect", False))
        while True:
            await asyncio.sleep(interval)
            if not self.ws.connected:
                continue
            # bandwidth gate (§6.4): only when a controller is present, unless
            # configured to always collect.
            if not (always or self.controller_present):
                continue
            res = await asyncio.to_thread(self.thumbnailer.capture)
            if not res:
                continue
            seq, jpeg = res
            await self.ws.send("thumb_meta", {
                "device_id": self.device_id, "seq": seq,
                "bytes": len(jpeg), "mime": "image/jpeg"})
            await self.ws.send_binary(jpeg)

    # --- run ----------------------------------------------------------
    async def run(self) -> None:
        self.loop = asyncio.get_running_loop()
        # §14: decide client vs p2p server from discovery (blocking probe off
        # the loop), build the transport, THEN bring up OS subsystems so the
        # discovery responder can advertise the chosen topology/broker_hint.
        self.decision = await asyncio.to_thread(self._discover_decision)
        self.ws = self._build_transport(self.decision)
        self.start_os_subsystems()
        # apply persisted volume/mute and runtime mode to mpv up front
        await self._mpv("set_volume", self.volume)
        await self._mpv("set_mute", self.muted)
        await self._resume_last()
        self._ws_task = asyncio.create_task(self.ws.run(), name="ws")
        tasks = [
            self._ws_task,
            asyncio.create_task(self.status_loop(), name="status"),
            asyncio.create_task(self.thumbnail_loop(), name="thumb"),
            asyncio.create_task(self.kiosk_loop(), name="kiosk"),
            asyncio.create_task(self.eof_watch_loop(), name="eof"),
        ]
        try:
            await asyncio.gather(*tasks)
        except asyncio.CancelledError:
            pass
        finally:
            await self.shutdown()

    async def kiosk_loop(self) -> None:
        """Periodically re-assert fullscreen/ontop + taskbar-hidden (§11)."""
        while True:
            await asyncio.sleep(5.0)
            if self.kiosk is not None:
                try:
                    self.kiosk.reassert()
                except Exception:
                    pass
            await self._mpv("ensure_kiosk")

    async def shutdown(self) -> None:
        try:
            if self.ws is not None:
                await self.ws.stop()
        except Exception:
            pass
        if self.discovery is not None:
            self.discovery.stop()
        if self.cohost_broker is not None:
            self.cohost_broker.stop()
        self.downloader.stop()
        if self.watchdog is not None:
            self.watchdog.stop()
        if self.kiosk is not None:
            self.kiosk.release()


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="LAN Media Wall — Windows player")
    parser.add_argument("--config", "-c", default=None,
                        help="path to config.yaml (else env LMW_CONFIG/defaults)")
    parser.add_argument("--broker", action="store_true", default=None,
                        help="§14.2 cohosted: also run the broker in-process "
                             "(this machine becomes the coordinator)")
    parser.add_argument("--pair", default=None,
                        help="§15 paste an lmw://pair?... URI to fill "
                             "host/port/group/mode/psk before connecting")
    parser.add_argument("--mode", default=None,
                        choices=["open", "optional", "required"],
                        help="§13 override auth_mode (else config/env/default)")
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    cfg = config_mod.load_config(args.config)
    # §15: a pairing URI overrides broker/auth/group before anything connects.
    if args.pair:
        try:
            fields = pairing_mod.parse_pairing_uri(args.pair)
            overlay = pairing_mod.pairing_to_config_overlay(fields)
            config_mod.apply_pairing(cfg, overlay)
            log.info("applied pairing URI: %s", sorted(fields))
        except pairing_mod.PairingError as exc:
            log.error("ignoring bad --pair URI: %s", exc)
    # §13: explicit --mode wins over file/env.
    if args.mode:
        cfg.raw["auth_mode"] = args.mode

    log.info("LAN Media Wall player — protocol v%d (auth_mode=%s)",
             1, cfg.auth_mode)
    player = Player(cfg, cohost=args.broker)
    log.info("device_id=%s name=%s group=%s ip=%s cohost=%s",
             player.device_id, player.device_name, player.group_id,
             player.ip, player.cohost)
    try:
        asyncio.run(player.run())
    except KeyboardInterrupt:
        log.info("interrupted, shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(main())
