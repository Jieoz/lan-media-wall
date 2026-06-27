"""UDP discovery on port 8772 (§7 + §14.5).

The broker can broadcast its own `announce` (carrying `topology`, `auth_mode`
and `broker_hint`, §13/§14) so endpoints auto-find it without hand-typing an IP,
and it answers `discover` packets with a unicast `announce`. It also accepts
player `announce` packets to refresh last-known IPs in the registry.

Signature handling follows the active auth_mode (§13): inbound packets are gated
by `envelope.verify_inbound`; outbound packets are built by the caller (the Hub)
so they carry the right sig (real HMAC or empty). Control traffic always stays
on the WS connection — UDP is discovery/fallback only.
"""
from __future__ import annotations

import asyncio
import socket
from typing import Callable, Optional

import envelope

DISCOVERY_PORT = 8772


class DiscoveryProtocol(asyncio.DatagramProtocol):
    def __init__(self, psk: str, auth_mode: str,
                 on_announce: Callable[[dict, tuple], None],
                 on_discover: Optional[Callable[[dict, tuple], None]] = None,
                 key_mode: str = envelope.KEY_GLOBAL):
        self.psk = psk
        self.auth_mode = auth_mode
        self.key_mode = envelope.normalize_key_mode(key_mode)
        self.on_announce = on_announce
        self.on_discover = on_discover
        self.transport: Optional[asyncio.DatagramTransport] = None
        self._dedup = envelope.MsgIdCache()

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data: bytes, addr):
        try:
            env = envelope.parse(data.decode("utf-8"))
        except Exception:
            return
        # Same auth gate as WS (§13): mode decides whether sig is checked. In
        # derived key_mode (§17) the device_key is derived from the packet's own
        # `from` identity, so a spoofed `from` fails to verify.
        if not envelope.verify_inbound(env, self.psk, self.auth_mode,
                                       self.key_mode):
            return
        # ts-window + msg_id dedup run in every mode (replay hygiene, §13 table).
        if not envelope.check_ts(env["ts"], first=True):
            return
        if self._dedup.seen(env["msg_id"]):
            return
        mtype = env.get("type")
        if mtype == "announce":
            try:
                self.on_announce(env, addr)
            except Exception:
                pass
        elif mtype == "discover" and self.on_discover is not None:
            try:
                self.on_discover(env, addr)
            except Exception:
                pass

    def error_received(self, exc):
        # Non-fatal; UDP best-effort.
        pass


class Discovery:
    def __init__(self, psk: str, on_announce: Callable[[dict, tuple], None],
                 port: int = DISCOVERY_PORT, *,
                 auth_mode: str = envelope.AUTH_OPEN,
                 on_discover: Optional[Callable[[dict, tuple], None]] = None,
                 key_mode: str = envelope.KEY_GLOBAL):
        self.psk = psk
        self.auth_mode = envelope.normalize_auth_mode(auth_mode)
        self.key_mode = envelope.normalize_key_mode(key_mode)
        self.on_announce = on_announce
        self.on_discover = on_discover
        self.port = port
        self.transport: Optional[asyncio.DatagramTransport] = None
        self.protocol: Optional[DiscoveryProtocol] = None

    async def start(self) -> None:
        loop = asyncio.get_running_loop()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.bind(("0.0.0.0", self.port))
        self.transport, self.protocol = await loop.create_datagram_endpoint(
            lambda: DiscoveryProtocol(
                self.psk, self.auth_mode, self.on_announce, self.on_discover,
                key_mode=self.key_mode),
            sock=sock,
        )

    def send_to(self, env: dict, addr) -> None:
        """Unicast a (caller-built) envelope to a specific (host, port)."""
        if self.transport is None:
            return
        self.transport.sendto(envelope.dumps(env).encode("utf-8"), addr)

    def broadcast(self, env: dict) -> None:
        """Broadcast a (caller-built) envelope to the LAN broadcast address."""
        if self.transport is None:
            return
        data = envelope.dumps(env).encode("utf-8")
        self.transport.sendto(data, ("255.255.255.255", self.port))

    def broadcast_discover(self, from_: str = "broker") -> None:
        """Send a discover broadcast to the LAN (signed per auth_mode/§17)."""
        env = envelope.build_envelope(
            "discover", {}, from_, "all", self.psk,
            sign=envelope.should_sign(self.auth_mode, self.psk),
            key_mode=self.key_mode,
        )
        self.broadcast(env)

    def stop(self) -> None:
        if self.transport is not None:
            self.transport.close()
            self.transport = None
