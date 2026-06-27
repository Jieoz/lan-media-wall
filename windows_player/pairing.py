"""`lmw://pair?...` pairing-URI intake (protocol_spec §15, §17.4).

A Windows operator can paste a pairing string instead of hand-filling the
broker host/port/group/mode/psk. §15.1 grammar:

    lmw://pair?host=<ip>&port=<8770>&group=<gid>&mode=<open|optional|required>
              &psk=<hex?>&wss=<0|1>&name=<可选预设名>

§17.4 derived-mode pairing (zero-PSK endpoints) carries instead of `psk`:
    &key_mode=derived&dk=<device_key hex>&id=<identity>&bk=<broker key hex?>
  - `dk` = this end's own device_key (HMAC(PSK, id)), used to *sign* our frames.
  - `id` = this end's identity (the `from` we sign as, e.g. player:win-1).
  - `bk` = the broker's verify key (HMAC(PSK, "broker")), used to *verify*
    inbound broker frames without ever holding the PSK (see NOTES_TO_UPSTREAM —
    additive field bridging the §17.4 gap on how a PSK-less end verifies broker
    frames). The endpoint never receives the PSK in derived mode.

Rules (§15.1):
  - `open` mode carries **no** psk/dk ("纯扫一下进组").
  - `required`/`optional` + global → §3 32+ byte hex PSK (`psk`).
  - `required`/`optional` + derived → `dk`+`id` (+optional `bk`), no `psk`.
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

    Returns keys among: host, port, group, mode, key_mode, psk, dk, id, bk,
    wss(bool), name. Absent fields are simply omitted. Unknown query params are
    dropped (§15.1 forward-compat). `open` mode with no psk yields no `psk` key.

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

    # §17.3 key_mode: derived | global. Absent → caller infers (dk present →
    # derived, else global), so an old QR with only `psk` stays global.
    key_mode = _first(qs, "key_mode")
    if key_mode:
        out["key_mode"] = auth.normalize_key_mode(unquote(key_mode))

    # psk only meaningful for optional/required + global; open carries none
    # and derived replaces it with dk/bk (§15.1, §17.4).
    psk = _first(qs, "psk")
    if psk:
        out["psk"] = unquote(psk)

    # §17.4 derived material: our own device_key (dk) + identity (id), and the
    # optional broker verify key (bk). Hex strings, validated downstream.
    dk = _first(qs, "dk")
    if dk:
        out["dk"] = unquote(dk)

    ident = _first(qs, "id")
    if ident:
        out["id"] = unquote(ident)

    bk = _first(qs, "bk")
    if bk:
        out["bk"] = unquote(bk)

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

    # §17: key_mode is explicit if given, else inferred — `dk` present means a
    # derived-mode QR, otherwise stay global (an old `psk`-only QR is global).
    if "key_mode" in fields:
        overlay["key_mode"] = fields["key_mode"]
    elif "dk" in fields:
        overlay["key_mode"] = auth.KEY_MODE_DERIVED

    # §17.4 derived material lands under a dedicated `derived_key` block so it
    # never collides with the global `psk` and is trivial to ignore in global.
    derived: Dict[str, Any] = {}
    if "dk" in fields:
        derived["device_key"] = fields["dk"]
    if "id" in fields:
        derived["identity"] = fields["id"]
    if "bk" in fields:
        derived["broker_key"] = fields["bk"]
    if derived:
        overlay["derived_key"] = derived

    device: Dict[str, Any] = {}
    if "group" in fields:
        device["group_id"] = fields["group"]
    if "name" in fields:
        device["name"] = fields["name"]
    if device:
        overlay["device"] = device

    return overlay
