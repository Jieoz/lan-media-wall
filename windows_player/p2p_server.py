"""p2p server-mode transport (protocol_spec §14.3).

Mode C: no broker exists. The controller becomes the coordinator and dials
each player directly, so **the player runs a WS *server*** on 8770 instead of
dialing out. Everything else (playback / cache / status / three-phase
handshake response) is unchanged — only the transport *role* and the *clock
source* flip:

  - On controller connect we answer `welcome` with `topology:"p2p"` (we play
    the broker's welcome role, §14.3).
  - **Controller = master clock.** We still run the §8 handshake to learn our
    offset to it: we *send* `time_sync` to the controller and feed its
    `time_sync_ack` into ClockSync, exactly as against a broker. If a
    controller instead *sends* us a `time_sync` (treating us as a peer), we
    answer `time_sync_ack` echoing its t1 with our recv/send stamps — harmless
    and robust either way.
  - Inbound `prepare`/`play_at`/controls dispatch through the *same* handlers
    the player already uses against a broker (Player.on_message).

This class exposes the same surface `BrokerClient` does — `connected`,
`run()`, `send()`, `send_binary()`, `stop()` — so `Player` swaps transports
without touching its protocol logic. The two pure helpers (welcome payload,
time_sync_ack payload) are unit-tested; the WS serve loop is thin I/O.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Awaitable, Callable, Dict, Optional

import websockets
from websockets.exceptions import ConnectionClosed

import auth as auth_mod
import envelope
import topology
from clock import ClockSync, now_ms

log = logging.getLogger("lmw.p2p")

HandlerType = Callable[[str, Dict[str, Any], Dict[str, Any]], Awaitable[None]]


def build_welcome_payload(server_time: int, *, group_id: str,
                          auth_mode: str) -> Dict[str, Any]:
    """The `welcome` we (acting as coordinator) send the controller (§14.3).

    Declares topology:"p2p" and our auth_mode so the controller adapts (§13).
    server_time is our local clock — but the controller is authoritative for
    sync (§14.3), so this is diagnostic only."""
    return {
        "assigned": True,
        "server_time": int(server_time),
        "v": envelope.PROTOCOL_VERSION,
        "group_id": group_id,
        "topology": topology.P2P,
        "auth_mode": auth_mod.normalize_mode(auth_mode),
    }


def build_time_sync_ack_payload(t1: int, t2: int, t3: int,
                                req_msg_id: Optional[str] = None) -> Dict[str, Any]:
    """Reply to an inbound `time_sync` (§8.1), should a controller send one.

    Echoes t1 and carries our recv (t2) / send (t3) stamps + req_msg_id for
    unambiguous correlation (§8.1 [v1.1])."""
    payload: Dict[str, Any] = {"t1": int(t1), "t2": int(t2), "t3": int(t3)}
    if req_msg_id is not None:
        payload["req_msg_id"] = req_msg_id
    return payload


class P2PServer:
    """WS server transport for p2p mode. One controller client at a time
    (§14.4 discourages multi-controller in p2p)."""

    def __init__(self, *, psk: str, device_id: str, group_id: str,
                 clock: ClockSync, auth_state: auth_mod.AuthState,
                 on_connect: Optional[Callable[[], Awaitable[None]]] = None,
                 on_message: Optional[HandlerType] = None,
                 listen_host: str = "0.0.0.0",
                 listen_port: int = topology.P2P_LISTEN_PORT,
                 time_sync_interval_s: float = 30.0,
                 ping_interval_s: float = 20.0):
        self.psk = psk
        self.device_id = device_id
        self.frm = f"player:{device_id}"
        self.group_id = group_id
        self.clock = clock
        self.auth = auth_state
        self.on_connect = on_connect
        self.on_message = on_message
        self.listen_host = listen_host
        self.listen_port = listen_port
        self.time_sync_interval_s = time_sync_interval_s
        self.ping_interval_s = ping_interval_s

        self._ws = None  # the single connected controller
        self._server = None
        self._replay = envelope.ReplayCache()
        self._stop = asyncio.Event()
        self._send_lock = asyncio.Lock()
        self._first_connect = True
        self._pending_sync: Dict[str, int] = {}

    @property
    def connected(self) -> bool:
        return self._ws is not None

    # --- public send API (mirrors BrokerClient) ----------------------
    async def send(self, type_: str, payload: Dict[str, Any],
                   to: str = "controller", *,
                   msg_id: Optional[str] = None) -> Optional[str]:
        if not self.connected:
            return None
        env = envelope.build_envelope(self.psk, type_, self.frm, to, payload,
                                      msg_id=msg_id,
                                      sign_frame=self.auth.should_sign())
        data = json.dumps(env, ensure_ascii=False)
        try:
            async with self._send_lock:
                await self._ws.send(data)
            return env["msg_id"]
        except ConnectionClosed:
            return None

    async def send_binary(self, data: bytes) -> bool:
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
        """Serve until stop(). One controller connection handled at a time."""
        try:
            self._server = await websockets.serve(
                self._handle_controller, self.listen_host, self.listen_port,
                ping_interval=self.ping_interval_s,
                ping_timeout=self.ping_interval_s,
                max_size=8 * 1024 * 1024,
            )
        except OSError as exc:
            log.error("p2p server cannot bind %s:%d (%s)",
                      self.listen_host, self.listen_port, exc)
            return
        log.info("p2p server listening on %s:%d (mode C, controller=clock)",
                 self.listen_host, self.listen_port)
        try:
            await self._stop.wait()
        finally:
            self._server.close()
            await self._server.wait_closed()

    async def _handle_controller(self, ws) -> None:
        if self._ws is not None:
            # §14.4: a second controller in p2p risks clock-master conflict.
            log.warning("rejecting extra controller in p2p (one at a time)")
            await ws.close(code=1013, reason="p2p single controller")
            return
        self._ws = ws
        self.clock.reset()  # §1: re-handshake on every (re)connect
        log.info("controller connected to p2p server")
        try:
            # send welcome immediately (we are the coordinator now).
            await self.send("welcome", build_welcome_payload(
                now_ms(), group_id=self.group_id, auth_mode=self.auth.mode),
                to="controller")
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
        except ConnectionClosed:
            pass
        finally:
            self._ws = None
            self._first_connect = False
            log.info("controller disconnected from p2p server")

    async def _recv_loop(self) -> None:
        async for raw in self._ws:
            if isinstance(raw, (bytes, bytearray)):
                continue  # controller→player binary is unused
            await self._handle_text(raw)

    async def _handle_text(self, raw: str) -> None:
        try:
            env = json.loads(raw)
        except json.JSONDecodeError:
            return
        ok, reason = envelope.verify(
            self.psk, env, replay=self._replay,
            first_connect=self._first_connect,
            auth_mode=self.auth.mode)
        if not ok:
            log.debug("p2p dropped inbound (%s): type=%s", reason,
                      env.get("type"))
            return
        type_ = env.get("type")
        payload = env.get("payload", {})
        if type_ == "time_sync_ack":
            # controller answered *our* probe → learn offset to its clock.
            self._on_time_sync_ack(env, payload)
            return
        if type_ == "time_sync":
            # controller probing us → answer as the spec's ack-er (§8.1).
            await self._answer_time_sync(env, payload)
            return
        if type_ == "hello":
            # controller's hello to us; nothing to register, welcome already sent.
            return
        if self.on_message:
            try:
                await self.on_message(type_, payload, env)
            except Exception:
                log.exception("p2p handler error for type=%s", type_)

    # --- §8 clock: controller is master ------------------------------
    async def _sync_loop(self) -> None:
        while not self._stop.is_set() and self.connected:
            await self._send_time_sync()
            await asyncio.sleep(self.time_sync_interval_s)

    async def _send_time_sync(self) -> None:
        t1 = now_ms()
        mid = await self.send("time_sync", {"t1": t1}, to="controller")
        if mid:
            self._pending_sync[mid] = t1
            if len(self._pending_sync) > 64:
                self._pending_sync.pop(next(iter(self._pending_sync)))

    def _on_time_sync_ack(self, env: Dict[str, Any],
                          payload: Dict[str, Any]) -> None:
        t4 = now_ms()
        try:
            t1 = int(payload["t1"])
            t2 = int(payload["t2"])
            t3 = int(payload["t3"])
        except (KeyError, TypeError, ValueError):
            return
        req_mid = payload.get("req_msg_id") or payload.get("msg_id")
        if req_mid and req_mid in self._pending_sync:
            t1 = self._pending_sync.pop(req_mid)
        s = self.clock.add_sample(t1, t2, t3, t4)
        log.debug("p2p time_sync: offset=%.1fms rtt=%.1fms", s.offset, s.rtt)

    async def _answer_time_sync(self, env: Dict[str, Any],
                                payload: Dict[str, Any]) -> None:
        t2 = now_ms()
        try:
            t1 = int(payload["t1"])
        except (KeyError, TypeError, ValueError):
            return
        await self.send("time_sync_ack", build_time_sync_ack_payload(
            t1, t2, now_ms(), req_msg_id=env.get("msg_id")), to="controller")

    async def stop(self) -> None:
        self._stop.set()
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass
