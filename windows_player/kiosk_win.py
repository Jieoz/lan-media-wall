"""Windows 10 kiosk hardening (§11): hide the taskbar, keep the player window
fullscreen/top-most, never reveal the desktop.

mpv already runs borderless-fullscreen-ontop. This module adds the OS-level
belt-and-suspenders on Windows: hide the shell taskbar (Shell_TrayWnd) and the
secondary taskbars, and optionally re-assert the mpv window as top-most.

Everything is guarded behind `sys.platform == "win32"` and a soft import of
pywin32, so the module imports cleanly on Linux/CI and simply becomes a no-op.
"""

from __future__ import annotations

import sys
from typing import Optional

IS_WIN = sys.platform == "win32"

# Soft imports — absent on non-Windows / CI.
_win32gui = None
_win32con = None
if IS_WIN:  # pragma: no cover - Windows only
    try:
        import win32gui as _win32gui  # type: ignore
        import win32con as _win32con  # type: ignore
    except Exception:
        _win32gui = None
        _win32con = None


def available() -> bool:
    """True only on Windows with pywin32 present."""
    return IS_WIN and _win32gui is not None


def _find_taskbars():  # pragma: no cover - Windows only
    bars = []
    primary = _win32gui.FindWindow("Shell_TrayWnd", None)
    if primary:
        bars.append(primary)
    # secondary monitor taskbars
    hwnd = 0
    while True:
        hwnd = _win32gui.FindWindowEx(0, hwnd, "Shell_SecondaryTrayWnd", None)
        if not hwnd:
            break
        bars.append(hwnd)
    return bars


def hide_taskbar() -> bool:
    """Hide all taskbars. Returns True if action was taken."""
    if not available():
        return False
    # pragma: no cover - Windows only
    for hwnd in _find_taskbars():
        _win32gui.ShowWindow(hwnd, _win32con.SW_HIDE)
    return True


def show_taskbar() -> bool:
    """Restore the taskbar(s) — called on graceful shutdown."""
    if not available():
        return False
    # pragma: no cover - Windows only
    for hwnd in _find_taskbars():
        _win32gui.ShowWindow(hwnd, _win32con.SW_SHOW)
    return True


def raise_window(title_substr: str = "mpv") -> bool:
    """Force the mpv window top-most and foreground (anti desktop-leak)."""
    if not available():
        return False
    # pragma: no cover - Windows only
    target = []

    def _enum(hwnd, _):
        try:
            t = _win32gui.GetWindowText(hwnd)
        except Exception:
            t = ""
        if t and title_substr.lower() in t.lower():
            target.append(hwnd)

    _win32gui.EnumWindows(_enum, None)
    if not target:
        return False
    hwnd = target[0]
    _win32gui.SetWindowPos(
        hwnd, _win32con.HWND_TOPMOST, 0, 0, 0, 0,
        _win32con.SWP_NOMOVE | _win32con.SWP_NOSIZE | _win32con.SWP_SHOWWINDOW)
    try:
        _win32gui.SetForegroundWindow(hwnd)
    except Exception:
        pass
    return True


class KioskGuard:
    """Convenience lifecycle wrapper used by main."""

    def __init__(self, enabled: bool = True):
        self.enabled = enabled and IS_WIN
        self._engaged = False

    def engage(self) -> None:
        if self.enabled:
            hide_taskbar()
            self._engaged = True

    def reassert(self) -> None:
        if self.enabled and self._engaged:
            hide_taskbar()
            raise_window()

    def release(self) -> None:
        if self.enabled and self._engaged:
            show_taskbar()
            self._engaged = False
