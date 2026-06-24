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

from typing import Tuple

OPEN = "open"
OPTIONAL = "optional"
REQUIRED = "required"
VALID_MODES = (OPEN, OPTIONAL, REQUIRED)
DEFAULT_MODE = OPEN  # §15.3: ship open so the default case is zero-config.

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
    """Mutable holder for the endpoint's effective auth mode + PSK.

    Starts from the locally configured/announced mode and is updated in place
    when the coordinator's `welcome` (or a pre-connect `announce`) reveals the
    authoritative mode. The WS transports consult it on every send/verify so a
    mode change takes effect immediately on the next frame."""

    def __init__(self, mode: object, psk: object):
        self.mode = normalize_mode(mode)
        self.psk = psk if isinstance(psk, str) else ""

    @property
    def has_psk(self) -> bool:
        return has_usable_psk(self.psk)

    def should_sign(self) -> bool:
        return should_sign(self.mode, self.has_psk)

    def should_verify(self, sig: str) -> bool:
        return should_verify(self.mode, sig)

    def can_operate(self) -> Tuple[bool, str]:
        return can_operate(self.mode, self.has_psk)

    def adopt(self, mode: object) -> bool:
        """Adopt the coordinator's advertised mode. Returns True if it changed.

        A missing/None value leaves the current mode untouched (the coordinator
        simply didn't declare one — stay where we are)."""
        if mode is None:
            return False
        new = normalize_mode(mode)
        if new != self.mode:
            self.mode = new
            return True
        return False
