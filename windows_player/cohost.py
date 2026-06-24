"""Cohosted-broker launch (protocol_spec §14.2).

Mode B: this player *also* runs the broker, in-process, so no extra machine is
needed. To other endpoints it's just a broker that happens to share a host with
one player; the local player connects to it at 127.0.0.1:8770 like any client
(topology.decide_topology handles that wiring). We UDP-announce our broker_hint
(via the existing DiscoveryResponder) so other endpoints discover us (§7).

Contract coordination note (see NOTES_TO_UPSTREAM): the brief specifies a
`run_broker(config)` entry on the broker package, but the broker currently
exposes `async def run(cfg: dict)` (plus `load_config`). We resolve **either**
shape defensively. The broker module also uses bare top-level imports
(`import clock`, `import envelope`, …) whose names collide with this package's
modules, so importing it in-process requires its own directory on sys.path
*first* and is best done in an isolated thread with its own event loop. If the
import can't be satisfied here (collision / missing dep), we log clearly and
let the player keep connecting — the broker can also be started as a separate
process — rather than crashing (§ red line: no crash).

`resolve_broker_entry` is **pure** (takes a module-like object, returns a
zero-arg coroutine factory) and is unit-tested with fakes. The thread spawn is
thin I/O around it.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
import threading
from typing import Any, Awaitable, Callable, Dict, Optional

log = logging.getLogger("lmw.cohost")

# repo-root-relative location of the broker package (sibling of windows_player).
BROKER_DIRNAME = "broker"


def resolve_broker_entry(
    broker_module: Any, cfg: Dict[str, Any]
) -> Callable[[], Awaitable[None]]:
    """Return a zero-arg coroutine factory that runs the broker with `cfg`.

    Accepts either documented shape, in priority order:
      1. `run_broker(config)` — the entry named in the brief.
      2. `run(cfg)`           — the broker's actual current entry.
    Both may be sync-returning-awaitable or async def; we wrap uniformly.

    Raises AttributeError if neither entry exists, so the caller can fall back
    to "broker started separately" instead of guessing."""
    entry = None
    for name in ("run_broker", "run"):
        cand = getattr(broker_module, name, None)
        if callable(cand):
            entry = cand
            break
    if entry is None:
        raise AttributeError(
            "broker module exposes neither run_broker(config) nor run(cfg)")

    async def _factory() -> None:
        result = entry(cfg)
        if asyncio.iscoroutine(result):
            await result

    return _factory


def _broker_dir() -> Optional[str]:
    """Best-effort absolute path to the sibling broker/ package."""
    here = os.path.dirname(os.path.abspath(__file__))
    cand = os.path.normpath(os.path.join(here, os.pardir, BROKER_DIRNAME))
    return cand if os.path.isdir(cand) else None


def _load_broker_module():
    """Import the broker package, putting its dir on sys.path FIRST so its bare
    imports resolve to the broker's own modules, not ours. Returns the module
    or raises."""
    bdir = _broker_dir()
    if bdir is None:
        raise ModuleNotFoundError(f"broker dir not found next to {__file__}")
    if bdir not in sys.path:
        sys.path.insert(0, bdir)
    import importlib
    return importlib.import_module("broker")


def build_broker_config(psk: str, *, auth_mode: str, ws_port: int = 8770,
                        discovery_port: int = 8772,
                        base: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Assemble the cfg dict the broker's entry expects.

    Starts from the broker's own DEFAULTS (`base`, passed by start() so we
    never duplicate/maintain the broker's required keys like `state_path` /
    `buffer_ms`), then layers our cohost-specific overrides. Called in tests
    with base=None to assert just the override keys."""
    cfg: Dict[str, Any] = dict(base or {})
    cfg.update({
        "psk": psk,
        "ws_port": ws_port,
        "wss_port": ws_port + 1,
        "discovery_port": discovery_port,
        "enable_discovery": False,  # the player's DiscoveryResponder announces
        "auth_mode": auth_mode,
        "topology": "cohosted",
    })
    return cfg


class CohostBroker:
    """Runs the broker on a dedicated daemon thread with its own event loop, so
    it lives alongside the player's asyncio loop without sharing it."""

    def __init__(self, cfg: Dict[str, Any]):
        self.cfg = cfg
        self._thread: Optional[threading.Thread] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self.started = False
        self.error: Optional[str] = None

    def start(self) -> bool:
        """Spawn the broker. Returns True if the thread launched (the import +
        run happen on that thread; a late failure is recorded in `self.error`
        and logged, never raised into the player)."""
        try:
            module = _load_broker_module()
            factory = resolve_broker_entry(module, self.cfg)
        except Exception as exc:  # collision / missing dep / no entry
            self.error = f"{type(exc).__name__}: {exc}"
            log.error("cohost broker unavailable in-process (%s); "
                      "start the broker separately and this player will "
                      "connect to 127.0.0.1:8770", self.error)
            return False

        # Layer the broker's own DEFAULTS *underneath* our overrides so required
        # keys (state_path, buffer_ms, …) are present without us hardcoding the
        # broker's schema. Our cohost overrides (psk/ports/auth) win.
        base = getattr(module, "DEFAULTS", None)
        if isinstance(base, dict):
            merged = dict(base)
            merged.update(self.cfg)
            self.cfg = merged
            factory = resolve_broker_entry(module, self.cfg)

        def _run() -> None:
            loop = asyncio.new_event_loop()
            self._loop = loop
            asyncio.set_event_loop(loop)
            try:
                loop.run_until_complete(factory())
            except Exception as exc:  # pragma: no cover - runtime broker death
                self.error = f"{type(exc).__name__}: {exc}"
                log.error("cohost broker stopped: %s", self.error)
            finally:
                loop.close()

        self._thread = threading.Thread(target=_run, name="cohost-broker",
                                        daemon=True)
        self._thread.start()
        self.started = True
        log.info("cohost broker thread started (mode B); local player will "
                 "connect to 127.0.0.1:%s", self.cfg.get("ws_port", 8770))
        return True

    def stop(self) -> None:
        if self._loop is not None:
            try:
                self._loop.call_soon_threadsafe(self._loop.stop)
            except Exception:
                pass
