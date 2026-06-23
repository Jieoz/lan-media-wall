"""mpv process supervision + crash/hang recovery + resume_last (§10, §11).

The watchdog OWNS the mpv process: it spawns mpv with the kiosk args, then
every check_interval_s confirms the process is alive AND its IPC is responsive
(a simple get_property ping detects a hung-but-not-dead mpv). On failure it
restarts mpv within restart_grace_s and invokes a `resume_last` callback so the
player returns to its last task (persisted locally).

Pure process logic; the actual replay is delegated to a callback supplied by
main so the watchdog stays decoupled from playback semantics.
"""

from __future__ import annotations

import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable, List, Optional

from mpv_controller import MpvController, mpv_launch_args

IS_WIN = sys.platform == "win32"


class MpvWatchdog:
    def __init__(self, mpv_path: str, ipc_path: str, *,
                 idle_image: Optional[str] = None,
                 extra_args: Optional[List[str]] = None,
                 check_interval_s: float = 1.0,
                 restart_grace_s: float = 5.0,
                 on_restart: Optional[Callable[[MpvController], None]] = None):
        self.mpv_path = mpv_path
        self.ipc_path = ipc_path
        self.idle_image = idle_image
        self.extra_args = extra_args or []
        self.check_interval_s = check_interval_s
        self.restart_grace_s = restart_grace_s
        self.on_restart = on_restart

        self._proc: Optional[subprocess.Popen] = None
        self._ctl: Optional[MpvController] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self.restarts = 0

    @property
    def controller(self) -> Optional[MpvController]:
        return self._ctl

    def start(self) -> MpvController:
        """Spawn mpv, attach IPC, then run the supervision loop in a thread."""
        self._spawn()
        self._thread = threading.Thread(target=self._loop, name="mpv-watchdog",
                                        daemon=True)
        self._thread.start()
        return self._ctl  # type: ignore[return-value]

    def _spawn(self) -> None:
        with self._lock:
            args = [self.mpv_path] + mpv_launch_args(
                self.ipc_path, idle_image=self.idle_image, extra=self.extra_args)
            # On POSIX, clean up a stale socket so connect() doesn't grab it.
            if not IS_WIN:
                try:
                    Path(self.ipc_path).unlink(missing_ok=True)
                except Exception:
                    pass
            creationflags = 0
            if IS_WIN:  # pragma: no cover - Windows only
                # CREATE_NO_WINDOW so no console flashes behind the kiosk
                creationflags = 0x08000000
            self._proc = subprocess.Popen(
                args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                creationflags=creationflags)
            ctl = MpvController(self.ipc_path)
            ctl.connect()
            ctl.ensure_kiosk()
            self._ctl = ctl

    def _alive(self) -> bool:
        if self._proc is None or self._proc.poll() is not None:
            return False
        # liveness ping: hung mpv answers slowly/never → treated as dead
        try:
            self._ctl.get_property("idle-active") if self._ctl else None
            return True
        except Exception:
            return False

    def _loop(self) -> None:
        while not self._stop.is_set():
            time.sleep(self.check_interval_s)
            if self._stop.is_set():
                break
            if self._alive():
                continue
            self._restart()

    def _restart(self) -> None:
        self.restarts += 1
        # kill the old process within the grace window, then respawn + resume
        try:
            if self._ctl:
                self._ctl.close()
        except Exception:
            pass
        try:
            if self._proc and self._proc.poll() is None:
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=self.restart_grace_s)
                except subprocess.TimeoutExpired:
                    self._proc.kill()
        except Exception:
            pass
        if self._stop.is_set():
            return
        try:
            self._spawn()
            if self.on_restart and self._ctl:
                self.on_restart(self._ctl)
        except Exception:
            # leave it for the next loop tick to retry
            pass

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2.0)
        try:
            if self._ctl:
                self._ctl.close()
        except Exception:
            pass
        try:
            if self._proc and self._proc.poll() is None:
                self._proc.terminate()
        except Exception:
            pass
