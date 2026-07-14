r"""mpv control via JSON IPC (§9, §11).

We drive a real mpv.exe over its JSON IPC channel:
  - Windows: named pipe  \\.\pipe\lmw-mpv   (--input-ipc-server=...)
  - POSIX:   unix socket /tmp/lmw-mpv.sock  (dev/CI; same protocol)

Why IPC over libmpv/python-mpv: it survives a controller-process restart, is
trivially scriptable, and lets the watchdog own the mpv process lifecycle.

mpv is launched borderless, fullscreen, always-on-top, idle-on-empty so it
NEVER shows the desktop (§11). Audio/seek/screenshot/volume all map to mpv
properties or commands.

This module talks the wire protocol; it does not own the process — that's the
watchdog. `connect()` attaches to an already-spawned mpv's IPC endpoint.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time
from typing import Any, Dict, List, Optional

IS_WIN = sys.platform == "win32"


def mpv_launch_args(ipc_path: str, *, idle_image: Optional[str] = None,
                    hwdec: Optional[str] = "auto-safe",
                    extra: Optional[List[str]] = None) -> List[str]:
    """The kiosk/black-screen-proof mpv command line (§11).

    `hwdec` selects the mpv hardware-decoding mode (§9/§11 performance). The
    default `auto-safe` lets mpv pick a HW decoder only from the vetted/safe
    list (no fallbacks known to green/tear on flaky drivers), so low-end/山寨
    boxes stop soft-decoding high-bitrate video on the CPU. Set it to `no` (or
    empty) to disable HW decoding entirely when diagnosing green/garbled video
    — that reproduces the old software-only behaviour byte-for-byte. Any other
    string is passed straight through to `--hwdec=` so operators can pin a
    specific decoder (e.g. `d3d11va`, `mediacodec`) when they know their box.
    """
    args = [
        f"--input-ipc-server={ipc_path}",
        "--idle=yes",              # stay alive with empty playlist (no desktop)
        "--force-window=yes",      # always have a window, even when idle
        "--fullscreen=yes",
        "--ontop=yes",
        "--border=no",             # borderless
        "--no-osc",                # no on-screen controls
        "--osd-level=0",
        "--cursor-autohide=always",
        "--keep-open=yes",         # don't close window at end of file
        "--background=#000000",    # pure black behind/instead of video (§11)
        "--image-display-duration=inf",  # images held until we advance
        "--no-input-default-bindings",
        "--input-vo-keyboard=no",
        "--really-quiet",
    ]
    # §9/§11: hardware decoding. Normalise falsy/`no` → explicit off so the flag
    # is always present and deterministic across watchdog restarts.
    hw = (hwdec or "no").strip() or "no"
    if hw.lower() in ("no", "off", "none", "false", "0"):
        args.append("--hwdec=no")
    else:
        args.append(f"--hwdec={hw}")
    if idle_image:
        # show placeholder when idle instead of black; loaded explicitly too
        args.append(f"--idle=yes")
    if extra:
        args.extend(extra)
    return args


class MpvIPCError(RuntimeError):
    pass


class MpvController:
    """Thin, thread-safe JSON-IPC client for a running mpv instance."""

    def __init__(self, ipc_path: str, *, connect_timeout: float = 10.0):
        self.ipc_path = ipc_path
        self.connect_timeout = connect_timeout
        self._sock: Optional[socket.socket] = None
        self._pipe: Any = None  # Windows file handle
        self._lock = threading.Lock()
        self._req_id = 0
        self._rbuf = b""

    # --- connection ---------------------------------------------------
    def connect(self) -> None:
        """Attach to mpv's IPC endpoint, retrying until timeout (mpv may still
        be starting up)."""
        deadline = time.time() + self.connect_timeout
        last: Optional[Exception] = None
        while time.time() < deadline:
            try:
                if IS_WIN:
                    self._connect_pipe()
                else:
                    self._connect_unix()
                return
            except Exception as exc:  # not up yet
                last = exc
                time.sleep(0.25)
        raise MpvIPCError(f"could not connect to mpv IPC at {self.ipc_path}: {last}")

    def _connect_unix(self) -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(self.ipc_path)
        self._sock = s

    def _connect_pipe(self) -> None:  # pragma: no cover - Windows only
        # Named pipes behave like files on Windows; open r+b binary.
        self._pipe = open(self.ipc_path, "r+b", buffering=0)

    @property
    def connected(self) -> bool:
        return self._sock is not None or self._pipe is not None

    def close(self) -> None:
        with self._lock:
            try:
                if self._sock:
                    self._sock.close()
                if self._pipe:
                    self._pipe.close()
            except Exception:
                pass
            self._sock = None
            self._pipe = None

    # --- low-level IO -------------------------------------------------
    def _write(self, data: bytes) -> None:
        if self._sock:
            self._sock.sendall(data)
        elif self._pipe:  # pragma: no cover - Windows only
            self._pipe.write(data)
            self._pipe.flush()
        else:
            raise MpvIPCError("not connected")

    def _readline(self, timeout: float) -> bytes:
        deadline = time.time() + timeout
        while b"\n" not in self._rbuf:
            if time.time() > deadline:
                raise MpvIPCError("ipc read timeout")
            chunk = b""
            if self._sock:
                try:
                    chunk = self._sock.recv(65536)
                except socket.timeout:
                    continue
            elif self._pipe:  # pragma: no cover - Windows only
                chunk = self._pipe.read(65536) or b""
            if not chunk:
                time.sleep(0.01)
                continue
            self._rbuf += chunk
        line, _, self._rbuf = self._rbuf.partition(b"\n")
        return line

    def _command(self, *cmd: Any, timeout: float = 3.0) -> Any:
        """Send a command and wait for the matching request_id reply."""
        with self._lock:
            self._req_id += 1
            rid = self._req_id
            msg = json.dumps({"command": list(cmd), "request_id": rid}) + "\n"
            self._write(msg.encode("utf-8"))
            # read until we see our reply (skip async events)
            deadline = time.time() + timeout
            while time.time() < deadline:
                line = self._readline(max(0.1, deadline - time.time()))
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line.decode("utf-8"))
                except json.JSONDecodeError:
                    continue
                if obj.get("request_id") == rid:
                    if obj.get("error") not in (None, "success"):
                        raise MpvIPCError(f"mpv error: {obj.get('error')} for {cmd}")
                    return obj.get("data")
            raise MpvIPCError(f"no reply for command {cmd}")

    # --- high-level controls (§9) ------------------------------------
    def set_property(self, name: str, value: Any) -> None:
        self._command("set_property", name, value)

    def get_property(self, name: str) -> Any:
        return self._command("get_property", name)

    def get_property_safe(self, name: str, default: Any = None) -> Any:
        try:
            return self._command("get_property", name)
        except Exception:
            return default

    def loadfile(self, path: str, mode: str = "replace",
                 options: Optional[Dict[str, Any]] = None) -> None:
        """Load a media file/URL. options become per-file mpv options."""
        if options:
            opt = ",".join(f"{k}={v}" for k, v in options.items())
            self._command("loadfile", path, mode, opt)
        else:
            self._command("loadfile", path, mode)

    def play_paused(self, path: str, *, seek_ms: int = 0) -> None:
        """Preload a file paused at seek position — used by `prepare` so the
        decoder is primed and play_at just flips pause off (§9.1)."""
        self.set_property("pause", True)
        self.loadfile(path, "replace")
        # wait briefly for the file to load before seeking
        self._wait_seekable(timeout=5.0)
        if seek_ms > 0:
            self.seek_abs_ms(seek_ms)

    def _wait_seekable(self, timeout: float) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.get_property_safe("seekable", False) or \
               self.get_property_safe("duration") is not None:
                return
            time.sleep(0.05)

    def seek_abs_ms(self, ms: int) -> None:
        self._command("seek", ms / 1000.0, "absolute", "exact")

    def set_pause(self, paused: bool) -> None:
        self.set_property("pause", bool(paused))

    def set_loop_file(self, loop: bool) -> None:
        """§6.3 repeat-one: mpv loops the current file inside its own decoder
        (`loop-file=inf`) — seamless, single decoder, no reload seam. Cleared to
        `no` for the other loop modes so eof-driven advance still fires."""
        self.set_property("loop-file", "inf" if loop else "no")

    def stop(self) -> None:
        # clears the playlist; with --idle/--force-window mpv shows black, not
        # the desktop (§11)
        self._command("stop")

    def playlist_next(self) -> None:
        self._command("playlist-next", "force")

    def playlist_prev(self) -> None:
        self._command("playlist-prev", "force")

    def set_volume(self, vol: int) -> None:
        self.set_property("volume", max(0, min(100, int(vol))))

    def set_mute(self, muted: bool) -> None:
        self.set_property("mute", bool(muted))

    def screenshot_to(self, path: str, include_subs: bool = False) -> None:
        # "video" = current decoded frame without OSD; falls back if unavailable
        self._command("screenshot-to-file", path, "video" if not include_subs else "subtitles")

    def show_image(self, path: str) -> None:
        """Display a still image (idle placeholder or image playlist item)."""
        self.loadfile(path, "replace")

    def ensure_kiosk(self) -> None:
        """Re-assert fullscreen/ontop/borderless in case anything changed."""
        for prop, val in (("fullscreen", True), ("ontop", True),
                          ("border", False)):
            try:
                self.set_property(prop, val)
            except Exception:
                pass

    # --- introspection for status (§5) -------------------------------
    def snapshot(self) -> Dict[str, Any]:
        """Best-effort read of position/duration/pause/volume/mute/path."""
        pos = self.get_property_safe("time-pos")
        dur = self.get_property_safe("duration")
        return {
            "position_ms": int(pos * 1000) if isinstance(pos, (int, float)) else 0,
            "duration_ms": int(dur * 1000) if isinstance(dur, (int, float)) else 0,
            "paused": bool(self.get_property_safe("pause", True)),
            "idle": bool(self.get_property_safe("idle-active", True)),
            "volume": int(self.get_property_safe("volume", 100) or 0),
            "muted": bool(self.get_property_safe("mute", False)),
            "path": self.get_property_safe("path"),
            "eof": bool(self.get_property_safe("eof-reached", False)),
        }
