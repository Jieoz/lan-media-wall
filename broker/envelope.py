"""Message envelope: build/parse + HMAC sign/verify + msg_id dedup + ts check.

Implements §2 (envelope) and §3 (HMAC / anti-replay) of protocol_spec.md.
The signing string and canonical JSON form are defined by the spec and MUST
match every other endpoint byte-for-byte.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import time
import uuid
from collections import OrderedDict
from typing import Any, Optional

PROTOCOL_VERSION = 1

# §3 anti-replay windows (milliseconds).
TS_WINDOW_MS = 30_000
TS_WINDOW_FIRST_MS = 120_000
# §3 msg_id dedup retention.
DEDUP_TTL_MS = 5 * 60 * 1000


class EnvelopeError(Exception):
    """Base class for envelope rejection reasons."""


class BadSignature(EnvelopeError):
    pass


class StaleTimestamp(EnvelopeError):
    pass


class DuplicateMessage(EnvelopeError):
    pass


class MalformedEnvelope(EnvelopeError):
    pass


def canonical_json(payload: Any) -> str:
    """Canonical JSON form used inside the signing string (§3)."""
    return json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )


def signing_string(v: int, type_: str, msg_id: str, ts: int,
                    from_: str, to: str, payload: Any) -> str:
    """Exactly the layout from §3."""
    return f"{v}|{type_}|{msg_id}|{ts}|{from_}|{to}|{canonical_json(payload)}"


def compute_sig(psk: str, v: int, type_: str, msg_id: str, ts: int,
                from_: str, to: str, payload: Any) -> str:
    msg = signing_string(v, type_, msg_id, ts, from_, to, payload).encode("utf-8")
    return hmac.new(psk.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def now_ms() -> int:
    return int(time.time() * 1000)


def build_envelope(type_: str, payload: dict, from_: str, to: str, psk: str,
                   *, msg_id: Optional[str] = None, ts: Optional[int] = None,
                   v: int = PROTOCOL_VERSION) -> dict:
    """Construct a fully-signed envelope dict ready to json.dumps + send."""
    if payload is None:
        payload = {}
    msg_id = msg_id or str(uuid.uuid4())
    ts = ts if ts is not None else now_ms()
    sig = compute_sig(psk, v, type_, msg_id, ts, from_, to, payload)
    return {
        "v": v,
        "type": type_,
        "msg_id": msg_id,
        "ts": ts,
        "from": from_,
        "to": to,
        "sig": sig,
        "payload": payload,
    }


def dumps(env: dict) -> str:
    return json.dumps(env, ensure_ascii=False)


def parse(raw: str) -> dict:
    """Parse a text frame into an envelope dict, validating required keys."""
    try:
        env = json.loads(raw)
    except (ValueError, TypeError) as exc:
        raise MalformedEnvelope(f"not JSON: {exc}") from exc
    if not isinstance(env, dict):
        raise MalformedEnvelope("envelope is not an object")
    for key in ("v", "type", "msg_id", "ts", "from", "to", "sig", "payload"):
        if key not in env:
            raise MalformedEnvelope(f"missing field: {key}")
    if not isinstance(env["payload"], dict):
        raise MalformedEnvelope("payload is not an object")
    if not isinstance(env["ts"], int):
        raise MalformedEnvelope("ts is not an int")
    return env


def verify_sig(env: dict, psk: str) -> bool:
    """Recompute the HMAC and constant-time compare (§3.1)."""
    expected = compute_sig(
        psk, env["v"], env["type"], env["msg_id"], env["ts"],
        env["from"], env["to"], env["payload"],
    )
    return hmac.compare_digest(expected, str(env.get("sig", "")))


def check_ts(ts: int, *, now: Optional[int] = None, first: bool = False) -> bool:
    """§3.2 — reject envelopes whose ts drifts outside the replay window."""
    now = now if now is not None else now_ms()
    window = TS_WINDOW_FIRST_MS if first else TS_WINDOW_MS
    return abs(now - ts) <= window


class MsgIdCache:
    """LRU + TTL dedup cache for msg_id (§3.3)."""

    def __init__(self, ttl_ms: int = DEDUP_TTL_MS, max_size: int = 50_000):
        self.ttl_ms = ttl_ms
        self.max_size = max_size
        self._seen: "OrderedDict[str, int]" = OrderedDict()

    def _evict(self, now: int) -> None:
        # Drop expired entries from the front (oldest insertion order).
        while self._seen:
            msg_id, exp = next(iter(self._seen.items()))
            if exp <= now:
                self._seen.popitem(last=False)
            else:
                break
        while len(self._seen) > self.max_size:
            self._seen.popitem(last=False)

    def seen(self, msg_id: str, *, now: Optional[int] = None) -> bool:
        """Return True if msg_id was seen recently; otherwise record it."""
        now = now if now is not None else now_ms()
        self._evict(now)
        if msg_id in self._seen and self._seen[msg_id] > now:
            return True
        self._seen[msg_id] = now + self.ttl_ms
        self._seen.move_to_end(msg_id)
        return False
