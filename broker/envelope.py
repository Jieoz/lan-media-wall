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
# Minor version the broker implements (v1.3 additions; see protocol_spec §13–17).
# `v` itself stays 1 — v1.3 is purely additive (spec §12 / v1.3 preamble).
PROTOCOL_MINOR = 3

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

# §17 key_mode: how the HMAC key is chosen when signing is active.
#   derived — per-endpoint device_key = HMAC(PSK, identity) (v1.3, leak isolation)
#   global  — the raw PSK as the HMAC key (v1.2 behaviour, backward compat)
KEY_GLOBAL = "global"
KEY_DERIVED = "derived"
KEY_MODES = (KEY_GLOBAL, KEY_DERIVED)


def normalize_auth_mode(mode) -> str:
    """Coerce an arbitrary value to a valid auth_mode, defaulting to `open`."""
    m = str(mode).strip().lower() if mode is not None else AUTH_OPEN
    return m if m in AUTH_MODES else AUTH_OPEN


def normalize_key_mode(mode) -> str:
    """Coerce a value to a valid key_mode (§17.3).

    A missing/unknown value maps to `global` — i.e. the v1.2 behaviour. This is
    the on-the-wire default: when a peer's welcome/announce omits `key_mode` the
    receiver MUST treat it as `global` (spec §17.3, backward compat). A fresh
    broker *deployment* defaults to `derived` separately, in its config.
    """
    m = str(mode).strip().lower() if mode is not None else KEY_GLOBAL
    return m if m in KEY_MODES else KEY_GLOBAL


def derive_key(psk: str, identity: str) -> bytes:
    """Per-endpoint signing key (§17.2): device_key = HMAC_SHA256(PSK, identity).

    Returns the 32 raw bytes of the HMAC digest — used directly as the key of
    the next HMAC layer (do NOT hex-encode it first, spec §17.5). `identity` is
    the envelope `from` string verbatim (no normalization/lowercasing/trimming).
    """
    return hmac.new(psk.encode("utf-8"), identity.encode("utf-8"),
                    hashlib.sha256).digest()


def _signing_key(psk: str, key_mode: str, identity: str) -> bytes:
    """Resolve the raw HMAC key bytes for the active key_mode (§17.2/§17.3).

    derived -> device_key derived from `identity`; global -> the PSK bytes.
    """
    if normalize_key_mode(key_mode) == KEY_DERIVED:
        return derive_key(psk, identity)
    return psk.encode("utf-8")


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
                from_: str, to: str, payload: Any,
                key_mode: str = KEY_GLOBAL) -> str:
    """HMAC-SHA256 over the §3 signing string (§17.2 for the key choice).

    The signing-string layout, canonical JSON, ts and msg_id semantics are all
    unchanged from §3 — the ONLY variable is the HMAC key. In `derived` mode the
    key is the device_key of the *sender's own* identity (= `from_`); in `global`
    mode it is the raw PSK (v1.2 behaviour). `key_mode` defaults to `global` so
    existing callers keep the v1.2 contract.
    """
    msg = signing_string(v, type_, msg_id, ts, from_, to, payload).encode("utf-8")
    key = _signing_key(psk, key_mode, from_)
    return hmac.new(key, msg, hashlib.sha256).hexdigest()


def now_ms() -> int:
    return int(time.time() * 1000)


def build_envelope(type_: str, payload: dict, from_: str, to: str, psk: str,
                   *, msg_id: Optional[str] = None, ts: Optional[int] = None,
                   v: int = PROTOCOL_VERSION, sign: bool = True,
                   key_mode: str = KEY_GLOBAL) -> dict:
    """Construct an envelope dict ready to json.dumps + send.

    When `sign` is False (e.g. auth_mode `open`, see §13) the `sig` field is
    emitted as an empty string — the envelope structure (§2) is unchanged and
    `parse` still accepts it. `key_mode` (§17.3) selects the HMAC key: `derived`
    signs with the sender's device_key (from `from_`), `global` uses the PSK.
    """
    if payload is None:
        payload = {}
    msg_id = msg_id or str(uuid.uuid4())
    ts = ts if ts is not None else now_ms()
    sig = (compute_sig(psk, v, type_, msg_id, ts, from_, to, payload, key_mode)
           if sign else "")
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


def verify_sig(env: dict, psk: str, key_mode: str = KEY_GLOBAL) -> bool:
    """Recompute the HMAC and constant-time compare (§3.1 / §17.2).

    In `derived` mode the verifier takes the identity from the frame's `from`
    field, derives that identity's device_key from the PSK, and recomputes —
    so a frame signed with identity-A's key but claiming `from=identity-B` fails
    (the leak-isolation contract, §17.5). `global` mode verifies with the PSK.
    """
    expected = compute_sig(
        psk, env["v"], env["type"], env["msg_id"], env["ts"],
        env["from"], env["to"], env["payload"], key_mode,
    )
    return hmac.compare_digest(expected, str(env.get("sig", "")))


def verify_inbound(env: dict, psk: str, auth_mode: str,
                   key_mode: str = KEY_GLOBAL) -> bool:
    """Decide whether an *inbound* frame passes signature checking under the
    active auth_mode (§13). Returns True = accept, False = reject/drop.

    - required: strict verify, always (empty sig -> reject).
    - optional: verify only when `sig` is non-empty; empty sig is let through.
    - open:     never verify (accept regardless of sig). key_mode is moot here.

    `key_mode` (§17.3) is threaded into the signature recompute; it only matters
    when a sig is actually checked. The ts-window and msg_id dedup checks are
    *not* part of this gate — they run in every mode (replay hygiene needs no
    key, §13 table). Call them separately.
    """
    mode = normalize_auth_mode(auth_mode)
    if mode == AUTH_OPEN:
        return True
    if mode == AUTH_OPTIONAL:
        if not str(env.get("sig", "")):
            return True
        return verify_sig(env, psk, key_mode)
    # required
    return verify_sig(env, psk, key_mode)


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
