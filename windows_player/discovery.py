"""UDP discovery responder (§7).

Players listen on UDP 8772. A controller/broker broadcasts a `discover`
envelope; the player unicasts back an `announce` envelope (HMAC-signed like any
other message, §3) carrying device_id/name/ip and a broker_hint. Control still
flows over the broker WS; UDP is only for list refresh / IP backfill / fallback.

Runs on its own daemon thread with a blocking socket — independent of the
asyncio WS loop.
"""

from __future__ import annotations

import json
import socket
import threading
from typing import Any, Callable, Dict, Optional

import envelope
import auth as auth_mod


class DiscoveryResponder:
    def __init__(self, *, psk: str, device_id: str, device_name: str,
                 ip: str, broker_hint: str, port: int = 8772,
                 replay: Optional[envelope.ReplayCache] = None,
                 auth_mode: str = "open", topology: str = "dedicated",
                 key_mode: str = envelope.KEY_MODE_GLOBAL,
                 device_key: Optional[bytes] = None,
                 verify_keys: Optional[dict] = None):
        self.psk = psk
        self.device_id = device_id
        self.device_name = device_name
        self.ip = ip
        self.broker_hint = broker_hint
        self.port = port
        self.replay = replay or envelope.ReplayCache()
        # §13/§14: declare the coordinator's auth_mode + topology so probing
        # endpoints adapt (signing) and diagnose (role) without connecting.
        self.auth_mode = auth_mod.normalize_mode(auth_mode)
        self.topology = topology
        # §17: key_mode for signing our announce / verifying inbound discover.
        self.key_mode = auth_mod.normalize_key_mode(key_mode)
        self.device_key = device_key
        self.verify_keys = dict(verify_keys or {})
        self._sock: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="udp-discovery",
                                        daemon=True)
        self._thread.start()

    def _make_announce(self) -> bytes:
        # §13: sign the announce only when our mode calls for it (open → "").
        frm = f"player:{self.device_id}"
        has_material = auth_mod.has_usable_psk(self.psk) or (
            self.key_mode == envelope.KEY_MODE_DERIVED
            and self.device_key is not None)
        sign = auth_mod.should_sign(self.auth_mode, has_material)
        payload = {
            "device_id": self.device_id,
            "device_name": self.device_name,
            "ip": self.ip,
            "broker_hint": self.broker_hint,
            "auth_mode": self.auth_mode,
            "topology": self.topology,
            "key_mode": self.key_mode,
        }
        env = envelope.build_envelope(
            self.psk, "announce", frm, "all", payload,
            sign_frame=sign, key_mode=self.key_mode, device_key=self.device_key)
        return json.dumps(env, ensure_ascii=False).encode("utf-8")

    def _run(self) -> None:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            except Exception:
                pass
            s.bind(("", self.port))
            s.settimeout(1.0)
            self._sock = s
        except Exception:
            return
        while not self._stop.is_set():
            try:
                data, addr = self._sock.recvfrom(8192)
            except socket.timeout:
                continue
            except Exception:
                break
            self._handle(data, addr)

    def _handle(self, data: bytes, addr) -> None:
        try:
            env = json.loads(data.decode("utf-8"))
        except Exception:
            return
        if env.get("type") != "discover":
            return
        resolver = None
        verify_km = self.key_mode
        if self.key_mode == envelope.KEY_MODE_DERIVED and \
                not auth_mod.has_usable_psk(self.psk):
            keys = self.verify_keys
            resolver = lambda frm: keys.get(frm)  # noqa: E731
        ok, _ = envelope.verify(self.psk, env, replay=self.replay,
                                first_connect=True, auth_mode=self.auth_mode,
                                key_mode=verify_km, key_resolver=resolver)
        if not ok:
            return
        try:
            self._sock.sendto(self._make_announce(), addr)  # unicast reply
        except Exception:
            pass

    def update_ip(self, ip: str) -> None:
        self.ip = ip

    def stop(self) -> None:
        self._stop.set()
        try:
            if self._sock:
                self._sock.close()
        except Exception:
            pass
