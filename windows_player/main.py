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
from typing import Any, Dict, List, Optional

import config as config_mod
from clock import ClockSync, now_ms
from downloader import Downloader
from websocket_client import BrokerClient

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


VALID_STATES = {"playing", "paused", "idle", "buffering", "downloading"}


class Player:
    def __init__(self, cfg: config_mod.Config):
        self.cfg = cfg
        self.state = config_mod.PersistentState.load(cfg.state_dir)
        self.loop: Optional[asyncio.AbstractEventLoop] = None

        self.device_id = self.state.device_id
        self.device_name = self.state.device_name(
            cfg.get("device", "name"))
        self.group_id = self.state.group_id if self.state.group_id != "default" \
            else (cfg.get("device", "group_id") or "default")
        self.ip = config_mod.detect_ip(cfg.get("broker", "host", default="8.8.8.8"))

        self.clock = ClockSync()
        self.downloader = Downloader(
            cfg.cache_dir, on_change=self._on_cache_change)

        # playback state
        self.play_state = "idle"
        self.playlist: Optional[Dict[str, Any]] = None
        self.index = 0
        self.volume = 80
        self.muted = False
        self.audio_master = True
        self.controller_present = bool(
            cfg.get("thumbnail", "always_collect", default=False))
        self._errors: List[str] = []

        self._play_task: Optional[asyncio.Task] = None
        self._cache_dirty = asyncio.Event()

        # OS-coupled subsystems (created in start())
        self.watchdog = None
        self.mpv = None
        self.kiosk = None
        self.thumbnailer = None
        self.discovery = None

        self.ws = BrokerClient(
            cfg.broker_url, psk=cfg.psk, device_id=self.device_id,
            clock=self.clock, on_connect=self._on_connect,
            on_message=self._on_message,
            time_sync_interval_s=float(cfg.get("time_sync_interval_s", default=30)),
        )

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
            bh = f"{self.cfg.get('broker','host')}:{self.cfg.get('broker','port')}"
            self.discovery = DiscoveryResponder(
                psk=self.cfg.psk, device_id=self.device_id,
                device_name=self.device_name, ip=self.ip, broker_hint=bh,
                port=int(self.cfg.get("discovery", "udp_port", default=8772)))
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
            asyncio.run_coroutine_threadsafe(self._resume_last(), self.loop)
        else:
            self._apply_idle_screen()

    # --- §4 hello on (re)connect -------------------------------------
    async def _on_connect(self) -> None:
        await self.ws.send("hello", {
            "role": "player",
            "device_id": self.device_id,
            "device_name": self.device_name,
            "platform": "windows" if sys.platform == "win32" else "linux",
            "app_version": "1.0.0",
            "ip": self.ip,
            "screen": self._screen(),
            "capabilities": ["video", "image", "audio", "thumbnail"],
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
            "online": True,
            "group_id": self.group_id,
            "state": self._effective_state(snap),
            "current": current,
            "playlist_id": self.playlist.get("playlist_id") if self.playlist else None,
            "volume": int(snap.get("volume", self.volume) if snap else self.volume),
            "muted": bool(snap.get("muted", self.muted) if snap else self.muted),
            "audio_master": self.audio_master,
            "cache": self.downloader.cache_status(),
            "clock_offset_ms": self.clock.offset_ms,
            "cpu": self._cpu_percent(),
            "errors": self._errors[-5:],
        })

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
            "resume_last": self._h_resume_last,
            "welcome": self._h_welcome,
        }.get(type_)
        if handler is None:
            return
        await handler(payload, env)
        # ack commands that carry a msg_id (§10)
        if type_ in ("prepare", "pause", "resume", "stop", "next", "prev",
                     "set_volume", "set_mute", "set_audio_master",
                     "assign_group", "cache_prefetch", "playlist"):
            await self._ack(env, True)

    async def _ack(self, env: Dict[str, Any], ok: bool, err: str = "") -> None:
        await self.ws.send("ack", {"ack_of": env.get("msg_id"), "ok": ok,
                                   "err": err})

    async def _h_welcome(self, payload, env) -> None:
        # broker may override our group assignment via snapshot; honor it if
        # explicitly present for this device.
        if payload.get("assigned") is False:
            self._errors.append("not-assigned")

    # --- §6.2 cache_prefetch -----------------------------------------
    async def _h_cache_prefetch(self, payload, env) -> None:
        items = payload.get("items", [])
        if items:
            self.downloader.prefetch(items)

    # --- §6.3 playlist -----------------------------------------------
    async def _h_playlist(self, payload, env) -> None:
        self.playlist = payload
        self.index = 0
        self.state.store_playlist(payload)
        # eagerly prefetch everything referenced
        items = payload.get("items", [])
        if items:
            self.downloader.prefetch(items)
        # sync=false → broker drives single-box play_at=now separately; we just
        # store. sync=true → wait for prepare/play_at.

    # --- §9.1 prepare -------------------------------------------------
    async def _h_prepare(self, payload, env) -> None:
        pid = payload.get("playlist_id")
        start_index = int(payload.get("start_index", 0))
        seek_ms = int(payload.get("seek_ms", 0))
        pl = self._resolve_playlist(pid)
        ready = False
        if pl is not None:
            items = pl.get("items", [])
            if 0 <= start_index < len(items):
                item = items[start_index]
                self.playlist = pl
                self.index = start_index
                if self.downloader.is_ready(item["item_id"]):
                    path = str(self.downloader.ready_path(item["item_id"]))
                    await self._mpv("play_paused", path, seek_ms=seek_ms)
                    self.play_state = "buffering"
                    ready = True
                else:
                    # not cached yet — kick a fetch; report not-ready
                    self.downloader.prefetch([item])
        await self.ws.send("ready", {
            "device_id": self.device_id,
            "playlist_id": pid,
            "ready": ready,
        })

    # --- §9.2 play_at (the sync-critical path) -----------------------
    async def _h_play_at(self, payload, env) -> None:
        pid = payload.get("playlist_id")
        start_index = int(payload.get("start_index", self.index))
        seek_ms = int(payload.get("seek_ms", 0))
        play_at = int(payload.get("play_at", 0))
        pl = self._resolve_playlist(pid)
        if pl is None:
            return
        items = pl.get("items", [])
        if not (0 <= start_index < len(items)):
            return
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
        # cancel any pending scheduled start
        if self._play_task and not self._play_task.done():
            self._play_task.cancel()
        self._persist_last_task(pid, start_index, seek_ms)
        self._play_task = asyncio.create_task(
            self._scheduled_start(str(path), seek_ms, play_at, item))

    async def _scheduled_start(self, path: str, seek_ms: int, play_at: int,
                               item: Dict[str, Any]) -> None:
        """§8.2 fold play_at (master clock) → local target, prime paused, then
        unpause at the exact local instant."""
        # ensure file is loaded & paused at seek (idempotent if prepare did it)
        await self._mpv("play_paused", path, seek_ms=seek_ms)
        local_target = self.clock.to_local(play_at)
        # busy-wait the final stretch for sub-100ms accuracy; coarse-sleep first
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
        await self._mpv("set_pause", False)
        self.play_state = "playing"
        log.info("play_at fired: target_local=%d now=%d offset=%d",
                 local_target, now_ms(), self.clock.offset_ms)

    # --- §9.3 controls -----------------------------------------------
    async def _h_pause(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        await self._mpv("set_pause", True)
        self.play_state = "paused"

    async def _h_resume(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        play_at = payload.get("play_at")
        if play_at:
            local_target = self.clock.to_local(int(play_at))
            delay = max(0, local_target - now_ms())
            await asyncio.sleep(delay / 1000.0)
        await self._mpv("set_pause", False)
        self.play_state = "playing"

    async def _h_stop(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        if self._play_task and not self._play_task.done():
            self._play_task.cancel()
        await self._mpv("stop")
        self._apply_idle_screen()
        self.play_state = "idle"
        self._persist_last_task(None, 0, 0)

    async def _h_next(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        await self._advance(+1)

    async def _h_prev(self, payload, env) -> None:
        if not self._targets_me(payload):
            return
        await self._advance(-1)

    async def _advance(self, delta: int) -> None:
        if not self.playlist:
            return
        items = self.playlist.get("items", [])
        if not items:
            return
        loop = bool(self.playlist.get("loop", False))
        new_index = self.index + delta
        if new_index < 0 or new_index >= len(items):
            if loop:
                new_index %= len(items)
            else:
                return
        self.index = new_index
        item = items[new_index]
        path = self.downloader.ready_path(item["item_id"]) or item.get("url")
        if path:
            await self._mpv("loadfile", str(path), "replace")
            await self._mpv("set_pause", False)
            self.play_state = "playing"
            self._persist_last_task(self.playlist.get("playlist_id"),
                                    new_index, 0)

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
        return self.playlist  # best effort

    def _current_item(self) -> Optional[Dict[str, Any]]:
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

    async def _resume_last(self) -> None:
        """§10/§11: after a crash/reboot, return to the last task locally so the
        screen is never the desktop."""
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
        self.playlist = pl
        self.index = idx
        item = items[idx]
        path = self.downloader.ready_path(item["item_id"]) or item.get("url")
        if not path:
            self._apply_idle_screen()
            return
        await self._mpv("loadfile", str(path), "replace")
        await self._mpv("seek_abs_ms", int(task.get("seek_ms", 0)))
        await self._mpv("set_volume", int(task.get("volume", self.volume)))
        await self._mpv("set_mute", bool(task.get("muted", self.muted)))
        await self._mpv("set_pause", False)
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
        self.start_os_subsystems()
        # apply persisted volume/mute to mpv up front
        await self._mpv("set_volume", self.volume)
        tasks = [
            asyncio.create_task(self.ws.run(), name="ws"),
            asyncio.create_task(self.status_loop(), name="status"),
            asyncio.create_task(self.thumbnail_loop(), name="thumb"),
            asyncio.create_task(self.kiosk_loop(), name="kiosk"),
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
            await self.ws.stop()
        except Exception:
            pass
        if self.discovery is not None:
            self.discovery.stop()
        self.downloader.stop()
        if self.watchdog is not None:
            self.watchdog.stop()
        if self.kiosk is not None:
            self.kiosk.release()


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="LAN Media Wall — Windows player")
    parser.add_argument("--config", "-c", default=None,
                        help="path to config.yaml (else env LMW_CONFIG/defaults)")
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    cfg = config_mod.load_config(args.config)
    log.info("LAN Media Wall player — protocol v%d", 1)
    player = Player(cfg)
    log.info("device_id=%s name=%s group=%s ip=%s broker=%s",
             player.device_id, player.device_name, player.group_id,
             player.ip, cfg.broker_url)
    try:
        asyncio.run(player.run())
    except KeyboardInterrupt:
        log.info("interrupted, shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(main())
