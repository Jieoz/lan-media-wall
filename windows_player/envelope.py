"""Message envelope + HMAC signing/verification (protocol_spec §2, §3).

Pure logic, no I/O. Used by both the WS client (out/inbound) and tests.

Signing object (§3):
    f"{v}|{type}|{msg_id}|{ts}|{from}|{to}|{canonical_json(payload)}"
where canonical_json == json.dumps(payload, sort_keys=True,
separators=(",", ":"), ensure_ascii=False).
sig == HMAC_SHA256(PSK, that_string).hexdigest()
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time
import uuid
from collections import OrderedDict
from typing import Any, Dict, Optional, Tuple

PROTOCOL_VERSION = 1

# §3 thresholds
FRESH_WINDOW_MS = 30_000          # normal replay window
FIRST_CONNECT_WINDOW_MS = 120_000  # relaxed window right after connect
DEDUP_TTL_MS = 5 * 60 * 1000      # msg_id remembered for 5 minutes


def now_ms() -> int:
    """Local wall-clock epoch milliseconds (the spec's `ts`)."""
    return int(time.time() * 1000)


def canonical_json(payload: Dict[str, Any]) -> str:
    """Deterministic JSON used inside the signed string (§3)."""
    return json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )


def signing_string(
    v: int, type_: str, msg_id: str, ts: int, frm: str, to: str,
    payload: Dict[str, Any],
) -> str:
    return f"{v}|{type_}|{msg_id}|{ts}|{frm}|{to}|{canonical_json(payload)}"


def sign(psk: str, v: int, type_: str, msg_id: str, ts: int, frm: str,
         to: str, payload: Dict[str, Any]) -> str:
    msg = signing_string(v, type_, msg_id, ts, frm, to, payload).encode("utf-8")
    return hmac.new(psk.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def build_envelope(psk: str, type_: str, frm: str, to: str,
                   payload: Dict[str, Any], *, msg_id: Optional[str] = None,
                   ts: Optional[int] = None) -> Dict[str, Any]:
    """Construct a fully-signed outbound envelope."""
    v = PROTOCOL_VERSION
    msg_id = msg_id or str(uuid.uuid4())
    ts = now_ms() if ts is None else ts
    sig = sign(psk, v, type_, msg_id, ts, frm, to, payload)
    return {
        "v": v,
        "type": type_,
        "msg_id": msg_id,
        "ts": ts,
        "from": frm,
        "to": to,
        "sig": sig,
        "payload": payload,
    }


class ReplayCache:
    """LRU TTL cache of seen msg_ids for §3 dedup. Not thread-safe; callers
    on the asyncio receive loop use it from a single task."""

    def __init__(self, ttl_ms: int = DEDUP_TTL_MS, max_entries: int = 50_000):
        self.ttl_ms = ttl_ms
        self.max_entries = max_entries
        self._seen: "OrderedDict[str, int]" = OrderedDict()

    def _evict(self, now: int) -> None:
        # drop expired from the front (oldest insert first)
        while self._seen:
            mid, exp = next(iter(self._seen.items()))
            if exp <= now:
                self._seen.popitem(last=False)
            else:
                break
        while len(self._seen) > self.max_entries:
            self._seen.popitem(last=False)

    def seen(self, msg_id: str, now: Optional[int] = None) -> bool:
        """Return True if msg_id was already seen (and not expired). Records
        it as seen as a side effect when it is new."""
        now = now_ms() if now is None else now
        self._evict(now)
        if msg_id in self._seen and self._seen[msg_id] > now:
            return True
        self._seen[msg_id] = now + self.ttl_ms
        self._seen.move_to_end(msg_id)
        return False


def verify(psk: str, env: Dict[str, Any], *,
           replay: Optional[ReplayCache] = None,
           first_connect: bool = False,
           now: Optional[int] = None) -> Tuple[bool, str]:
    """Validate an inbound envelope per §3.

    Returns (ok, reason). reason is "" on success, else a short code:
    "shape", "sig", "stale", "dup".
    """
    now = now_ms() if now is None else now
    required = ("v", "type", "msg_id", "ts", "from", "to", "sig", "payload")
    if not isinstance(env, dict) or any(k not in env for k in required):
        return False, "shape"
    if not isinstance(env["payload"], dict):
        return False, "shape"

    expected = sign(psk, env["v"], env["type"], env["msg_id"], env["ts"],
                    env["from"], env["to"], env["payload"])
    # constant-time compare
    if not hmac.compare_digest(expected, str(env.get("sig", ""))):
        return False, "sig"

    window = FIRST_CONNECT_WINDOW_MS if first_connect else FRESH_WINDOW_MS
    try:
        ts = int(env["ts"])
    except (TypeError, ValueError):
        return False, "shape"
    if abs(now - ts) > window:
        return False, "stale"

    if replay is not None and replay.seen(str(env["msg_id"]), now):
        return False, "dup"

    return True, ""
