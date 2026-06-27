"""Message envelope + HMAC signing/verification (protocol_spec §2, §3, §17).

Pure logic, no I/O. Used by both the WS client (out/inbound) and tests.

Signing object (§3) — **unchanged** across v1.1/v1.2/v1.3:
    f"{v}|{type}|{msg_id}|{ts}|{from}|{to}|{canonical_json(payload)}"
where canonical_json == json.dumps(payload, sort_keys=True,
separators=(",", ":"), ensure_ascii=False).

§17 key derivation — the ONLY thing v1.3 changes is the HMAC *key*:
  - key_mode="global" (v1.2): key = PSK bytes (legacy, backward compatible).
  - key_mode="derived" (v1.3): key = device_key = HMAC_SHA256(PSK, identity),
    where `identity` is the sender's `from` field verbatim (no normalization).
    sig = HMAC_SHA256(device_key, signing_string).hexdigest().
The verifier re-derives the *sender's* device_key from `from` and compares —
so a key minted for identity-A cannot sign a frame claiming `from`=identity-B
(§17.5 leak isolation).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time
import uuid
from collections import OrderedDict
from typing import Any, Callable, Dict, Optional, Tuple

PROTOCOL_VERSION = 1

# §17.3 key_mode values. global = v1.2 (PSK direct); derived = v1.3 (per-end).
KEY_MODE_GLOBAL = "global"
KEY_MODE_DERIVED = "derived"

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


# --- §17 key derivation ------------------------------------------------------

def _as_key_bytes(key: Any) -> bytes:
    """Coerce a key (str PSK or raw 32-byte device_key) to the HMAC key bytes.

    A `str` is UTF-8 encoded (the v1.2 PSK path); `bytes`/`bytearray` are used
    verbatim (the §17 device_key path — raw binary, NOT hex-encoded)."""
    if isinstance(key, (bytes, bytearray)):
        return bytes(key)
    return str(key).encode("utf-8")


def derive_device_key(psk: str, identity: str) -> bytes:
    """§17.2: device_key = HMAC_SHA256(PSK, identity).digest() — 32 raw bytes.

    `identity` is the sender's `from` field **verbatim** — no normalization,
    lowercasing, or trimming (§17.5). The 32-byte binary digest is used
    directly as the next HMAC's key (never hex-encode it first)."""
    return hmac.new(psk.encode("utf-8"), identity.encode("utf-8"),
                    hashlib.sha256).digest()


def hmac_hex(key: Any, signing_str: str) -> str:
    """sig = HMAC_SHA256(key, signing_str).hexdigest(). `key` is PSK str or
    raw device_key bytes (§17.2)."""
    return hmac.new(_as_key_bytes(key), signing_str.encode("utf-8"),
                    hashlib.sha256).hexdigest()


def signing_key(psk: str, frm: str, key_mode: str = KEY_MODE_GLOBAL,
                *, device_key: Optional[bytes] = None) -> Any:
    """Resolve the HMAC key the *sender* must use for a frame from `frm`.

    global → the PSK itself (v1.2). derived → the sender's own device_key:
    an explicit `device_key` (a paired, PSK-less endpoint) is used as-is, else
    it is derived from the PSK on the fly (a coordinator that holds the PSK)."""
    if key_mode == KEY_MODE_DERIVED:
        if device_key is not None:
            return device_key
        return derive_device_key(psk, frm)
    return psk


def sign(psk: str, v: int, type_: str, msg_id: str, ts: int, frm: str,
         to: str, payload: Dict[str, Any], *,
         key_mode: str = KEY_MODE_GLOBAL,
         device_key: Optional[bytes] = None) -> str:
    """HMAC-sign a frame. Defaults to v1.2 global mode (key=PSK) so existing
    callers/tests are unchanged; pass key_mode="derived" for §17."""
    s = signing_string(v, type_, msg_id, ts, frm, to, payload)
    key = signing_key(psk, frm, key_mode, device_key=device_key)
    return hmac_hex(key, s)


def build_envelope(psk: str, type_: str, frm: str, to: str,
                   payload: Dict[str, Any], *, msg_id: Optional[str] = None,
                   ts: Optional[int] = None, sign_frame: bool = True,
                   key_mode: str = KEY_MODE_GLOBAL,
                   device_key: Optional[bytes] = None) -> Dict[str, Any]:
    """Construct an outbound envelope.

    `sign_frame` controls §13 auth adaptivity: when True (default, the
    `required`/signing case) the `sig` field carries a real HMAC; when False
    (the `open` case, or `optional` with no PSK) it is the empty string. The
    envelope shape (§2) is identical either way — only `sig` differs — so a
    parser never trips on an unsigned frame (§13).

    `key_mode`/`device_key` select the §17 signing key: global (default) uses
    the PSK verbatim (v1.2); derived signs with this end's own device_key
    (`device_key` if the end is PSK-less, else derived from the PSK)."""
    v = PROTOCOL_VERSION
    msg_id = msg_id or str(uuid.uuid4())
    ts = now_ms() if ts is None else ts
    sig = (sign(psk, v, type_, msg_id, ts, frm, to, payload,
                key_mode=key_mode, device_key=device_key)
           if sign_frame else "")
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
           now: Optional[int] = None,
           auth_mode: str = "required",
           key_mode: str = KEY_MODE_GLOBAL,
           key_resolver: Optional[Callable[[str], Any]] = None) -> Tuple[bool, str]:
    """Validate an inbound envelope per §3, gated by §13 `auth_mode`.

    Returns (ok, reason). reason is "" on success, else a short code:
    "shape", "sig", "stale", "dup".

    §13 controls only the signature check:
      - "required" (default): always verify `sig` — preserves v1 behavior.
      - "open":               never verify `sig` (it may be "").
      - "optional":           verify only when `sig` is non-empty.
    The ts-freshness and msg_id-dedup checks run in **all** modes — they are
    replay hygiene and need no key (§13).

    §17 key selection for the sig check:
      - key_mode="global" (default): the key is the PSK (v1.2 behavior).
      - key_mode="derived": the key is the *sender's* device_key. By default it
        is derived from the PSK and the frame's `from` (a coordinator holding
        the PSK can verify any sender statelessly, §17.2). A PSK-less endpoint
        passes `key_resolver(from) -> key_bytes|None` to map an identity to a
        pre-shared verify key (e.g. the broker key from pairing); returning
        None means "no key for this sender" → the sig check fails closed."""
    now = now_ms() if now is None else now
    required = ("v", "type", "msg_id", "ts", "from", "to", "sig", "payload")
    if not isinstance(env, dict) or any(k not in env for k in required):
        return False, "shape"
    if not isinstance(env["payload"], dict):
        return False, "shape"

    sig = str(env.get("sig", ""))
    if _verify_needed(auth_mode, sig):
        frm = env["from"]
        if key_resolver is not None:
            key = key_resolver(frm)
        elif key_mode == KEY_MODE_DERIVED:
            key = derive_device_key(psk, frm)
        else:
            key = psk
        if key is None:
            # §17: no verify key for this sender (PSK-less end, unknown `from`)
            # → fail closed rather than accept an unverifiable frame.
            return False, "sig"
        expected = hmac_hex(key, signing_string(
            env["v"], env["type"], env["msg_id"], env["ts"],
            env["from"], env["to"], env["payload"]))
        # constant-time compare
        if not hmac.compare_digest(expected, sig):
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


def _verify_needed(auth_mode: str, sig: str) -> bool:
    """§13 signature-check gate. Kept here (not importing `auth`) so envelope
    stays dependency-free; `auth.should_verify` is the canonical mirror."""
    mode = auth_mode if isinstance(auth_mode, str) else "required"
    mode = mode.strip().lower()
    if mode == "open":
        return False
    if mode == "optional":
        return bool(sig)
    return True  # required / unknown → strict (safe default)
