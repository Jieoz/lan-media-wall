"""Auth-mode adaptivity (protocol_spec §13).

§3's HMAC is still the *only* auth mechanism; §13 only makes it *optional* per
the coordinator's `auth_mode`. The coordinator (broker / cohost / p2p
controller) is authoritative and declares its mode in `welcome.payload.auth_mode`
and in the UDP `announce.payload.auth_mode`. Endpoints *adapt*:

| auth_mode  | we put `sig`            | we verify inbound            |
|------------|-------------------------|------------------------------|
| open       | "" (empty)              | no (ts + dedup still run)     |
| optional   | only if we hold a PSK    | only if `sig` is non-empty    |
| required   | always                  | always                        |

ts-freshness + msg_id dedup (§3) run in **all** modes — they are replay
hygiene and need no key. A keyless endpoint that meets `required` is a soft
error: keep retrying, log "needs PSK", never crash (§13).

This module is pure logic, no I/O — fully unit-tested.
"""

from __future__ import annotations

from typing import Any, Callable, Dict, Optional, Tuple

import envelope

OPEN = "open"
OPTIONAL = "optional"
REQUIRED = "required"
VALID_MODES = (OPEN, OPTIONAL, REQUIRED)
DEFAULT_MODE = OPEN  # §15.3: ship open so the default case is zero-config.

# §17.3 key_mode. global = v1.2 (PSK direct); derived = v1.3 (per-end key).
# Missing/unknown → global (backward compatible: a v1.2 coordinator that never
# declares key_mode is treated exactly as before).
KEY_MODE_GLOBAL = envelope.KEY_MODE_GLOBAL
KEY_MODE_DERIVED = envelope.KEY_MODE_DERIVED
VALID_KEY_MODES = (KEY_MODE_GLOBAL, KEY_MODE_DERIVED)
DEFAULT_KEY_MODE = KEY_MODE_GLOBAL

# PSKs we treat as "not really configured" — the shipped placeholder and the
# empty string. In open/optional these are fine (we just don't sign).
PLACEHOLDER_PSKS = {"", "CHANGE_ME_32_BYTE_RANDOM_PRESHARED_KEY"}


def normalize_mode(mode: object) -> str:
    """Coerce an arbitrary value to a valid auth_mode, defaulting to open.

    Unknown / missing / malformed values fall back to the spec default rather
    than raising, so a stray field can never take the player down (§13)."""
    if not isinstance(mode, str):
        return DEFAULT_MODE
    m = mode.strip().lower()
    return m if m in VALID_MODES else DEFAULT_MODE


def has_usable_psk(psk: object) -> bool:
    """True if `psk` is a real preshared key (not empty / not the placeholder)."""
    if not isinstance(psk, str):
        return False
    return psk not in PLACEHOLDER_PSKS


def normalize_key_mode(mode: object) -> str:
    """Coerce an arbitrary value to a valid key_mode (§17.3).

    Missing/unknown/malformed → global, i.e. v1.2 behavior. This is the
    backward-compatibility hinge: a coordinator that never declares key_mode
    is treated as global, exactly as before §17 existed."""
    if not isinstance(mode, str):
        return DEFAULT_KEY_MODE
    m = mode.strip().lower()
    return m if m in VALID_KEY_MODES else DEFAULT_KEY_MODE


def should_sign(mode: str, has_psk: bool) -> bool:
    """Whether an outbound frame should carry a real `sig` (§13).

    open      → never (send sig=""), required → always (caller gates on
    can_operate first), optional → only when we actually hold a PSK."""
    mode = normalize_mode(mode)
    if mode == OPEN:
        return False
    if mode == OPTIONAL:
        return has_psk
    return True  # REQUIRED


def should_verify(mode: str, sig: str) -> bool:
    """Whether an inbound frame's `sig` must be checked (§13).

    open      → never, required → always, optional → only if `sig` non-empty."""
    mode = normalize_mode(mode)
    if mode == OPEN:
        return False
    if mode == OPTIONAL:
        return bool(sig)
    return True  # REQUIRED


def can_operate(mode: str, has_psk: bool) -> Tuple[bool, str]:
    """Can this endpoint participate under `mode`?

    Returns (ok, reason). The only blocking case is `required` without a PSK —
    a soft error: the caller should keep retrying and surface "needs PSK", not
    crash (§13)."""
    mode = normalize_mode(mode)
    if mode == REQUIRED and not has_psk:
        return False, "needs PSK"
    return True, ""


class AuthState:
    """Mutable holder for the endpoint's effective auth mode + key material.

    Starts from the locally configured/announced mode and is updated in place
    when the coordinator's `welcome` (or a pre-connect `announce`) reveals the
    authoritative `auth_mode` and `key_mode`. The WS transports consult it on
    every send/verify so a mode change takes effect immediately on the next
    frame.

    §17 key material:
      - `psk`: held by coordinators (broker/cohost/p2p) and v1.2/global ends.
      - `device_key`: this end's own 32-byte key from §15 pairing, used to
        *sign* our frames in derived mode when we are PSK-less.
      - `identity`: our `from` string (`player:<id>`). device_key is bound to
        it (§17.2); used as the derivation input when we hold the PSK instead.
      - `verify_keys`: identity -> raw key bytes for verifying *inbound* frames
        when we are PSK-less (e.g. {"broker": <bk>} from pairing). Coordinators
        leave this empty and derive per-`from` from the PSK on the fly."""

    def __init__(self, mode: object, psk: object, *,
                 key_mode: object = DEFAULT_KEY_MODE,
                 identity: Optional[str] = None,
                 device_key: Optional[bytes] = None,
                 verify_keys: Optional[Dict[str, bytes]] = None):
        self.mode = normalize_mode(mode)
        self.psk = psk if isinstance(psk, str) else ""
        self.key_mode = normalize_key_mode(key_mode)
        self.identity = identity
        self.device_key = device_key
        self.verify_keys: Dict[str, bytes] = dict(verify_keys or {})

    @property
    def has_psk(self) -> bool:
        return has_usable_psk(self.psk)

    @property
    def has_key_material(self) -> bool:
        """Can we *sign*? True if we hold a usable PSK or (derived) a device_key.

        A PSK-less end that was paired in derived mode still signs with its
        device_key — so it is not a "needs key" soft error (§17.4)."""
        if self.has_psk:
            return True
        return self.key_mode == KEY_MODE_DERIVED and self.device_key is not None

    def should_sign(self) -> bool:
        # required → always (caller gates on can_operate); optional → only if we
        # actually hold key material; open → never.
        if self.mode == OPEN:
            return False
        if self.mode == OPTIONAL:
            return self.has_key_material
        return True  # REQUIRED

    def should_verify(self, sig: str) -> bool:
        return should_verify(self.mode, sig)

    def can_operate(self) -> Tuple[bool, str]:
        """Can this endpoint participate? The only blocking case is `required`
        with no usable key material (no PSK and no device_key) — a soft error
        (§13/§17.4): keep retrying, surface "needs PSK", never crash."""
        if self.mode == REQUIRED and not self.has_key_material:
            return False, "needs PSK"
        return True, ""

    # --- §17 signing/verifying key resolution ------------------------
    def sign_kwargs(self) -> Dict[str, Any]:
        """kwargs to pass build_envelope/sign so they use the right §17 key.

        global → {} (key=PSK). derived → key_mode + our device_key (PSK-less
        end) or just key_mode (we hold the PSK and derive from our identity)."""
        if self.key_mode != KEY_MODE_DERIVED:
            return {}
        if self.device_key is not None:
            return {"key_mode": KEY_MODE_DERIVED, "device_key": self.device_key}
        return {"key_mode": KEY_MODE_DERIVED}

    def verify_resolver(self) -> Optional[Callable[[str], Any]]:
        """A `from`->key resolver for envelope.verify in derived mode, or None.

        - global mode → None (verify uses the PSK directly).
        - derived + we hold the PSK → None (verify derives per-`from`, passing
          key_mode="derived" instead; coordinator path, stateless §17.2).
        - derived + PSK-less → a resolver over `verify_keys` (e.g. broker key
          from pairing); unknown identities map to None → fail closed."""
        if self.key_mode != KEY_MODE_DERIVED or self.has_psk:
            return None
        keys = self.verify_keys

        def _resolve(frm: str):
            return keys.get(frm)

        return _resolve

    def verify_key_mode(self) -> str:
        """The key_mode to pass envelope.verify (only meaningful when there is
        no resolver, i.e. the coordinator/PSK derive-on-the-fly path)."""
        return self.key_mode

    def adopt(self, mode: object) -> bool:
        """Adopt the coordinator's advertised auth_mode. Returns True if changed.

        A missing/None value leaves the current mode untouched (the coordinator
        simply didn't declare one — stay where we are)."""
        if mode is None:
            return False
        new = normalize_mode(mode)
        if new != self.mode:
            self.mode = new
            return True
        return False

    def adopt_key_mode(self, key_mode: object) -> bool:
        """Adopt the coordinator's advertised key_mode (§17.3). Returns True if
        changed. None leaves it untouched; any other value normalizes (missing
        field already arrived as None from `payload.get`, so absence → global
        only on first init, never a silent downgrade mid-session)."""
        if key_mode is None:
            return False
        new = normalize_key_mode(key_mode)
        if new != self.key_mode:
            self.key_mode = new
            return True
        return False
