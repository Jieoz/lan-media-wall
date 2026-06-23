"""UDP discovery on port 8772 (§7).

The broker can optionally broadcast `discover` packets; players unicast back
`announce` (signed per §3). The broker uses announce packets to refresh
last-known IPs in the registry. Control traffic always stays on the WS
connection — UDP is discovery/fallback only.
"""
from __future__ import annotations

import asyncio
import socket
from typing import Callable, Optional

import envelope

DISCOVERY_PORT = 8772


class DiscoveryProtocol(asyncio.DatagramProtocol):
    def __init__(self, psk: str, on_announce: Callable[[dict, tuple], None]):
        self.psk = psk
        self.on_announce = on_announce
        self.transport: Optional[asyncio.DatagramTransport] = None
        self._dedup = envelope.MsgIdCache()

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data: bytes, addr):
        try:
            env = envelope.parse(data.decode("utf-8"))
        except Exception:
            return
        # Verify signature + freshness + dedup, same rules as WS (§3).
        if not envelope.verify_sig(env, self.psk):
            return
        if not envelope.check_ts(env["ts"], first=True):
            return
        if self._dedup.seen(env["msg_id"]):
            return
        if env.get("type") == "announce":
            try:
                self.on_announce(env, addr)
            except Exception:
                pass

    def error_received(self, exc):
        # Non-fatal; UDP best-effort.
        pass


class Discovery:
    def __init__(self, psk: str, on_announce: Callable[[dict, tuple], None],
                 port: int = DISCOVERY_PORT):
        self.psk = psk
        self.on_announce = on_announce
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
            lambda: DiscoveryProtocol(self.psk, self.on_announce),
            sock=sock,
        )

    def broadcast_discover(self, from_: str = "broker") -> None:
        """Send a signed discover broadcast to the LAN."""
        if self.transport is None:
            return
        env = envelope.build_envelope(
            "discover", {}, from_, "all", self.psk,
        )
        data = envelope.dumps(env).encode("utf-8")
        self.transport.sendto(data, ("255.255.255.255", self.port))

    def stop(self) -> None:
        if self.transport is not None:
            self.transport.close()
            self.transport = None
