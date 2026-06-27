"""Active UDP discovery probe (protocol_spec §7 + §14.5).

On startup the player broadcasts a `discover` packet and listens for `announce`
replies for a short window. A reply that names a `broker_hint` means a
coordinator exists → run as a client to it (modes A/B). Silence means no broker
→ flip to p2p server mode (mode C). This is the active counterpart to the
passive DiscoveryResponder (which *answers* probes from controllers/brokers).

The parse from an announce envelope to a topology.BrokerFound is **pure** and
unit-tested; the socket broadcast/collect loop is thin I/O around it.
"""

from __future__ import annotations

import json
import socket
import time
from typing import Any, Dict, List, Optional

import auth
import envelope
import topology

DISCOVERY_PORT = 8772
DEFAULT_TIMEOUT_S = 3.0


def parse_announce(env: Dict[str, Any]) -> Optional[topology.BrokerFound]:
    """Turn an `announce` envelope into a BrokerFound, or None if it carries no
    usable broker_hint. Tolerant of missing/malformed v1.2 fields (§13/§14
    declare auth_mode/topology, but a v1.1 announce won't have them)."""
    if not isinstance(env, dict) or env.get("type") != "announce":
        return None
    payload = env.get("payload")
    if not isinstance(payload, dict):
        return None
    hint = payload.get("broker_hint")
    if not isinstance(hint, str) or not hint:
        return None
    host, port = _split_hint(hint)
    if host is None:
        return None
    return topology.BrokerFound(
        host=host,
        port=port,
        auth_mode=auth.normalize_mode(payload.get("auth_mode")),
        topology=payload.get("topology") or topology.DEDICATED,
        key_mode=auth.normalize_key_mode(payload.get("key_mode")),
    )


def _split_hint(hint: str) -> tuple[Optional[str], int]:
    """Split "host:port" → (host, port). Bare host → default WS port."""
    hint = hint.strip()
    if not hint:
        return None, topology.COHOST_BROKER_PORT
    if ":" in hint:
        host, _, p = hint.rpartition(":")
        try:
            return (host or None), int(p)
        except ValueError:
            return (host or None), topology.COHOST_BROKER_PORT
    return hint, topology.COHOST_BROKER_PORT


def pick_broker(announces: List[Dict[str, Any]]) -> Optional[topology.BrokerFound]:
    """From a batch of announce envelopes, pick the first that yields a broker.

    p2p peers also `announce` (they have no broker_hint, so parse_announce
    returns None for them) — only a real coordinator hint counts."""
    for env in announces:
        found = parse_announce(env)
        if found is not None:
            return found
    return None


def probe_for_broker(
    *, psk: str, auth_mode: str, device_id: str,
    port: int = DISCOVERY_PORT, timeout_s: float = DEFAULT_TIMEOUT_S,
    key_mode: str = envelope.KEY_MODE_GLOBAL,
    device_key: Optional[bytes] = None,
) -> Optional[topology.BrokerFound]:
    """Broadcast a `discover` and collect `announce` replies for `timeout_s`.

    Returns a BrokerFound if any reply names a broker_hint, else None (caller
    then flips to p2p server mode, §14.5). Signs the discover only when the
    local auth mode calls for it (§13) — an `open`-mode probe goes out with
    sig="" so an open coordinator answers it. §17: signs with our device_key
    in derived mode (or PSK-derived if we hold the PSK)."""
    has_material = auth.has_usable_psk(psk) or (
        key_mode == envelope.KEY_MODE_DERIVED and device_key is not None)
    sign = auth.should_sign(auth_mode, has_material)
    env = envelope.build_envelope(
        psk, "discover", f"player:{device_id}", "all", {},
        sign_frame=sign, key_mode=key_mode, device_key=device_key)
    data = json.dumps(env, ensure_ascii=False).encode("utf-8")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    except OSError:
        pass
    replies: List[Dict[str, Any]] = []
    try:
        sock.bind(("", 0))  # ephemeral source port; replies come back unicast
        sock.settimeout(0.5)
        try:
            sock.sendto(data, ("255.255.255.255", port))
        except OSError:
            return None
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            try:
                raw, _addr = sock.recvfrom(8192)
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                reply = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            replies.append(reply)
            found = parse_announce(reply)
            if found is not None:
                return found  # first usable broker wins; stop early
    finally:
        sock.close()
    return pick_broker(replies)
