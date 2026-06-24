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
# Minor version the broker implements (v1.2 additions; see protocol_spec §13–15).
# `v` itself stays 1 — v1.2 is purely additive (spec §12 / v1.2 preamble).
PROTOCOL_MINOR = 2

# §3 anti-replay windows (milliseconds).
TS_WINDOW_MS = 30_000
TS_WINDOW_FIRST_MS = 120_000
# §3 msg_id dedup retention.
DEDUP_TTL_MS = 5 * 60 * 1000

# §13 auth modes. `open` is the v1.2 default (zero-config, no PSK required).
AUTH_OPEN = "open"
AUTH_OPTIONAL = "optional"
AUTH_REQUIRED = "required"
AUTH_MODES = (AUTH_OPEN, AUTH_OPTIONAL, AUTH_REQUIRED)


def normalize_auth_mode(mode) -> str:
    """Coerce an arbitrary value to a valid auth_mode, defaulting to `open`."""
    m = str(mode).strip().lower() if mode is not None else AUTH_OPEN
    return m if m in AUTH_MODES else AUTH_OPEN


def should_sign(auth_mode: str, psk) -> bool:
    """Whether an *outbound* frame should carry a real HMAC sig (§13).

    - required: always sign (a PSK is mandatory in this mode).
    - optional: sign when a PSK is available, else emit sig:"".
    - open:     never sign (sig:"" — receivers don't verify).
    """
    mode = normalize_auth_mode(auth_mode)
    if mode == AUTH_REQUIRED:
        return True
    if mode == AUTH_OPTIONAL:
        return bool(psk)
    return False


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
                   v: int = PROTOCOL_VERSION, sign: bool = True) -> dict:
    """Construct an envelope dict ready to json.dumps + send.

    When `sign` is False (e.g. auth_mode `open`, see §13) the `sig` field is
    emitted as an empty string — the envelope structure (§2) is unchanged and
    `parse` still accepts it.
    """
    if payload is None:
        payload = {}
    msg_id = msg_id or str(uuid.uuid4())
    ts = ts if ts is not None else now_ms()
    sig = compute_sig(psk, v, type_, msg_id, ts, from_, to, payload) if sign else ""
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


def verify_inbound(env: dict, psk: str, auth_mode: str) -> bool:
    """Decide whether an *inbound* frame passes signature checking under the
    active auth_mode (§13). Returns True = accept, False = reject/drop.

    - required: strict verify, always (empty sig -> reject).
    - optional: verify only when `sig` is non-empty; empty sig is let through.
    - open:     never verify (accept regardless of sig).

    The ts-window and msg_id dedup checks are *not* part of this gate — they run
    in every mode (replay hygiene needs no key, §13 table). Call them separately.
    """
    mode = normalize_auth_mode(auth_mode)
    if mode == AUTH_OPEN:
        return True
    if mode == AUTH_OPTIONAL:
        if not str(env.get("sig", "")):
            return True
        return verify_sig(env, psk)
    # required
    return verify_sig(env, psk)


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
