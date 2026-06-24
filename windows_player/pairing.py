"""`lmw://pair?...` pairing-URI intake (protocol_spec §15).

A Windows operator can paste a pairing string instead of hand-filling the
broker host/port/group/mode/psk. §15.1 grammar:

    lmw://pair?host=<ip>&port=<8770>&group=<gid>&mode=<open|optional|required>
              &psk=<hex?>&wss=<0|1>&name=<可选预设名>

Rules (§15.1):
  - `open` mode carries **no** psk ("纯扫一下进组").
  - `required`/`optional` carry the §3 32+ byte hex PSK.
  - fields are standard URL-encoded.
  - **unknown query params are ignored** (forward-compat).

This is a pure client-side capability — it never touches the WS protocol
(§2–§12). It produces a config overlay that `config.apply_pairing` deep-merges
onto the loaded Config. Fully unit-tested.
"""

from __future__ import annotations

from typing import Any, Dict
from urllib.parse import parse_qs, unquote, urlparse

import auth

PAIR_SCHEME = "lmw"
PAIR_HOST = "pair"


class PairingError(ValueError):
    """Raised when a string is not a usable `lmw://pair?...` URI."""


def is_pairing_uri(text: object) -> bool:
    """Cheap prefix check so callers can branch before a full parse."""
    return isinstance(text, str) and text.strip().lower().startswith("lmw://")


def _first(qs: Dict[str, list], key: str) -> str | None:
    vals = qs.get(key)
    if not vals:
        return None
    v = vals[0]
    return v if v != "" else None


def parse_pairing_uri(uri: str) -> Dict[str, Any]:
    """Parse a pairing URI into a flat dict of the recognised fields.

    Returns keys among: host, port, group, mode, psk, wss(bool), name.
    Absent fields are simply omitted. Unknown query params are dropped (§15.1
    forward-compat). `open` mode with no psk yields no `psk` key.

    Raises PairingError on a non-lmw scheme, a non-`pair` action, or a port
    that isn't an int — those are structural, not "unknown field" cases."""
    if not isinstance(uri, str):
        raise PairingError("pairing URI must be a string")
    raw = uri.strip()
    parsed = urlparse(raw)
    if parsed.scheme.lower() != PAIR_SCHEME:
        raise PairingError(f"not an {PAIR_SCHEME}:// URI: {raw!r}")
    # urlparse puts "pair" in netloc for lmw://pair?... and in path for
    # lmw:///pair?... — accept either so a stray slash doesn't break pairing.
    action = (parsed.netloc or parsed.path.lstrip("/")).lower()
    if action != PAIR_HOST:
        raise PairingError(f"unsupported action {action!r}; expected 'pair'")

    qs = parse_qs(parsed.query, keep_blank_values=True)
    out: Dict[str, Any] = {}

    host = _first(qs, "host")
    if host:
        out["host"] = unquote(host)

    port = _first(qs, "port")
    if port is not None:
        try:
            out["port"] = int(port)
        except ValueError:
            raise PairingError(f"port not an integer: {port!r}")

    group = _first(qs, "group")
    if group:
        out["group"] = unquote(group)

    mode = _first(qs, "mode")
    if mode:
        # normalize so a typo'd mode degrades to the safe default (§13).
        out["mode"] = auth.normalize_mode(unquote(mode))

    # psk only meaningful for optional/required; open carries none (§15.1).
    psk = _first(qs, "psk")
    if psk:
        out["psk"] = unquote(psk)

    wss = _first(qs, "wss")
    if wss is not None:
        out["wss"] = wss.strip() in ("1", "true", "yes", "on")

    name = _first(qs, "name")
    if name:
        out["name"] = unquote(name)

    return out


def pairing_to_config_overlay(fields: Dict[str, Any]) -> Dict[str, Any]:
    """Turn parsed pairing fields into a Config-shaped overlay dict (the same
    nested shape as config.DEFAULTS) ready for a deep-merge.

    Only keys present in `fields` are emitted, so pasting a sparse URI tweaks
    just those settings and leaves the rest of the config intact."""
    overlay: Dict[str, Any] = {}
    broker: Dict[str, Any] = {}
    if "host" in fields:
        broker["host"] = fields["host"]
    if "port" in fields:
        broker["port"] = fields["port"]
    if "wss" in fields:
        broker["use_wss"] = bool(fields["wss"])
    if broker:
        overlay["broker"] = broker

    if "psk" in fields:
        overlay["psk"] = fields["psk"]
    if "mode" in fields:
        overlay["auth_mode"] = fields["mode"]

    device: Dict[str, Any] = {}
    if "group" in fields:
        device["group_id"] = fields["group"]
    if "name" in fields:
        device["name"] = fields["name"]
    if device:
        overlay["device"] = device

    return overlay
