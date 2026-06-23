"""WebSocket client to the broker (§1, §2, §3, §8).

Responsibilities:
  - Maintain one long-lived WS connection with exponential backoff reconnect
    (1,2,4,…,30s cap, §1).
  - Wrap outbound payloads in signed envelopes and verify inbound ones (§2/§3).
  - Drive the time_sync handshake on connect + every 30s, feeding ClockSync (§8).
  - Dispatch verified inbound messages to a handler callback supplied by main.
  - Send binary frames (thumbnails, §6.4).

Built on `websockets` (asyncio). The transport-layer ping is handled by the
library (ping_interval). On every (re)connect the owner is notified via
`on_connect` so it can re-hello + reset the clock (§1).
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Awaitable, Callable, Dict, Optional

import websockets
from websockets.exceptions import ConnectionClosed

import envelope
from clock import ClockSync, now_ms

log = logging.getLogger("lmw.ws")

HandlerType = Callable[[str, Dict[str, Any], Dict[str, Any]], Awaitable[None]]


class BrokerClient:
    def __init__(self, url: str, *, psk: str, device_id: str,
                 clock: ClockSync,
                 on_connect: Optional[Callable[[], Awaitable[None]]] = None,
                 on_message: Optional[HandlerType] = None,
                 time_sync_interval_s: float = 30.0,
                 ping_interval_s: float = 20.0):
        self.url = url
        self.psk = psk
        self.device_id = device_id
        self.frm = f"player:{device_id}"
        self.clock = clock
        self.on_connect = on_connect
        self.on_message = on_message
        self.time_sync_interval_s = time_sync_interval_s
        self.ping_interval_s = ping_interval_s

        self._ws = None
        self._replay = envelope.ReplayCache()
        self._stop = asyncio.Event()
        self._connected = asyncio.Event()
        self._first_connect = True
        self._send_lock = asyncio.Lock()
        # pending time_sync round-trips: msg_id -> t1
        self._pending_sync: Dict[str, int] = {}

    @property
    def connected(self) -> bool:
        return self._ws is not None and self._connected.is_set()

    # --- public send API ---------------------------------------------
    async def send(self, type_: str, payload: Dict[str, Any],
                   to: str = "broker", *, msg_id: Optional[str] = None) -> Optional[str]:
        """Build, sign, and send an envelope. Returns msg_id, or None if not
        currently connected (caller may retry after reconnect)."""
        if not self.connected:
            return None
        env = envelope.build_envelope(self.psk, type_, self.frm, to, payload,
                                      msg_id=msg_id)
        data = json.dumps(env, ensure_ascii=False)
        try:
            async with self._send_lock:
                await self._ws.send(data)
            return env["msg_id"]
        except ConnectionClosed:
            return None

    async def send_binary(self, data: bytes) -> bool:
        """Send a raw binary frame (thumbnail JPEG, §6.4). Must be preceded by
        a thumb_meta text frame by the caller."""
        if not self.connected:
            return False
        try:
            async with self._send_lock:
                await self._ws.send(data)
            return True
        except ConnectionClosed:
            return False

    # --- lifecycle ----------------------------------------------------
    async def run(self) -> None:
        """Connect/serve loop with exponential backoff (§1)."""
        backoff = 1.0
        while not self._stop.is_set():
            try:
                async with websockets.connect(
                    self.url, ping_interval=self.ping_interval_s,
                    ping_timeout=self.ping_interval_s,
                    max_size=8 * 1024 * 1024,
                    open_timeout=10,
                ) as ws:
                    self._ws = ws
                    self._connected.set()
                    backoff = 1.0  # reset on a good connection
                    log.info("connected to broker at %s", self.url)
                    # reset clock samples — §1 requires re-handshake on reconnect
                    self.clock.reset()
                    if self.on_connect:
                        await self.on_connect()
                    sync_task = asyncio.create_task(self._sync_loop())
                    try:
                        await self._recv_loop()
                    finally:
                        sync_task.cancel()
                        try:
                            await sync_task
                        except (asyncio.CancelledError, Exception):
                            pass
            except (OSError, ConnectionClosed, asyncio.TimeoutError) as exc:
                log.warning("broker connection failed/closed: %s", exc)
            except Exception as exc:  # don't let the loop die
                log.exception("unexpected WS error: %s", exc)
            finally:
                self._ws = None
                self._connected.clear()
                self._first_connect = False
            if self._stop.is_set():
                break
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)  # §1 cap 30s

    async def _recv_loop(self) -> None:
        async for raw in self._ws:
            if isinstance(raw, (bytes, bytearray)):
                # players don't expect inbound binary; ignore defensively
                continue
            await self._handle_text(raw)

    async def _handle_text(self, raw: str) -> None:
        try:
            env = json.loads(raw)
        except json.JSONDecodeError:
            return
        ok, reason = envelope.verify(
            self.psk, env, replay=self._replay,
            first_connect=self._first_connect)
        if not ok:
            log.debug("dropped inbound (%s): type=%s", reason, env.get("type"))
            return
        type_ = env.get("type")
        payload = env.get("payload", {})
        # time_sync_ack is handled internally to keep the clock authoritative
        if type_ == "time_sync_ack":
            self._on_time_sync_ack(env, payload)
            return
        if type_ == "welcome":
            # server_time is informational here; clock comes from time_sync.
            pass
        if self.on_message:
            try:
                await self.on_message(type_, payload, env)
            except Exception:
                log.exception("handler error for type=%s", type_)

    # --- time sync (§8) ----------------------------------------------
    async def _sync_loop(self) -> None:
        # immediate handshake on connect, then every interval
        while not self._stop.is_set() and self.connected:
            await self._send_time_sync()
            await asyncio.sleep(self.time_sync_interval_s)

    async def _send_time_sync(self) -> None:
        t1 = now_ms()
        mid = await self.send("time_sync", {"t1": t1})
        if mid:
            self._pending_sync[mid] = t1
            # bound the pending map
            if len(self._pending_sync) > 64:
                self._pending_sync.pop(next(iter(self._pending_sync)))

    def _on_time_sync_ack(self, env: Dict[str, Any], payload: Dict[str, Any]) -> None:
        t4 = now_ms()
        try:
            t1 = int(payload["t1"])
            t2 = int(payload["t2"])
            t3 = int(payload["t3"])
        except (KeyError, TypeError, ValueError):
            return
        # prefer our recorded t1 (defends against a tampered echo), fall back
        # to the echoed t1 if we can't correlate.
        echoed_mid = payload.get("msg_id")
        if echoed_mid and echoed_mid in self._pending_sync:
            t1 = self._pending_sync.pop(echoed_mid)
        s = self.clock.add_sample(t1, t2, t3, t4)
        log.debug("time_sync: offset=%.1fms rtt=%.1fms (best=%dms)",
                  s.offset, s.rtt, self.clock.offset_ms)

    async def stop(self) -> None:
        self._stop.set()
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass
