"""Zero-config pairing URI + QR (§15).

Builds the `lmw://pair?...` URI from the running broker's config so an operator
can scan it (or copy it) to onboard endpoints without hand-typing host/port/
group/mode/psk. Pure client-side capability — it touches no WS frame (§15.2).

URI shape (§15.1 + §17.4):

    lmw://pair?host=<ip>&port=<8770>&group=<gid>&mode=<open|optional|required>
              &key_mode=<global|derived>&psk=<hex?>&dk=<hex?>&id=<identity?>
              &wss=<0|1>&name=<optional preset name>

- `open` mode omits any key entirely (pure "scan to join", §15.1).
- `global` key_mode includes the §3 PSK (`psk=<hex>`) — the v1.2 entry ticket.
- `derived` key_mode (§17.4) carries the endpoint's own `dk=<device_key hex>` +
  `id=<identity>` and NEVER the PSK. The broker derives device_key from the PSK
  at QR-generation time; the endpoint stores only its device_key and never sees
  the PSK. Endpoint operation is unchanged: broker shows a code, endpoint scans.
- All values are standard URL-encoded; unknown query params are ignored by
  consumers (forward-compat, §15.1).
"""
from __future__ import annotations

import socket
from typing import Optional
from urllib.parse import parse_qs, quote, urlsplit

import envelope

PAIR_SCHEME = "lmw"
PAIR_HOST = "pair"


def local_ip() -> str:
    """Best-effort primary LAN IP (no packet actually sent). Falls back to
    127.0.0.1 when offline."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def build_pairing_uri(*, host: str, port: int = 8770, group: str = "default",
                      mode: str = envelope.AUTH_OPEN, psk: Optional[str] = None,
                      wss: bool = False, name: Optional[str] = None,
                      key_mode: str = envelope.KEY_GLOBAL,
                      identity: Optional[str] = None) -> str:
    """Assemble the `lmw://pair?...` URI (§15.1 + §17.4).

    Key material is included only outside `open` mode:
    - `key_mode=global`  -> emit the PSK (`psk=`), as in v1.2.
    - `key_mode=derived` -> emit the per-endpoint device_key (`dk=`, derived from
      the PSK and `identity`) plus `id=<identity>`, and NEVER the PSK (§17.4).
      Requires both `psk` (to derive from) and `identity`; if either is missing
      no key field is emitted (the QR becomes discovery-only) so we never leak.
    In `open` mode every key field is omitted regardless of inputs.
    """
    mode = envelope.normalize_auth_mode(mode)
    key_mode = envelope.normalize_key_mode(key_mode)
    parts = [
        ("host", host),
        ("port", str(port)),
        ("group", group),
        ("mode", mode),
        ("wss", "1" if wss else "0"),
    ]
    if mode != envelope.AUTH_OPEN:
        # §17.3: the coordinator declares key_mode so the endpoint knows whether
        # the carried secret is a PSK (global) or a device_key (derived).
        parts.append(("key_mode", key_mode))
        if key_mode == envelope.KEY_DERIVED:
            if psk and identity:
                parts.append(("dk", envelope.derive_key(psk, identity).hex()))
                parts.append(("id", identity))
        elif psk:
            parts.append(("psk", psk))
    if name:
        parts.append(("name", name))
    query = "&".join(f"{k}={quote(str(v), safe='')}" for k, v in parts)
    return f"{PAIR_SCHEME}://{PAIR_HOST}?{query}"


def parse_pairing_uri(uri: str) -> dict:
    """Parse an `lmw://pair?...` URI back into a dict (for tests / consumers).

    Unknown params are kept (so callers can inspect them) but consumers should
    ignore the ones they don't recognize (§15.1). `wss` is coerced to bool.
    """
    split = urlsplit(uri)
    if split.scheme != PAIR_SCHEME:
        raise ValueError(f"not an {PAIR_SCHEME}:// URI: {uri!r}")
    if split.netloc != PAIR_HOST:
        raise ValueError(f"unexpected pairing action: {split.netloc!r}")
    raw = parse_qs(split.query, keep_blank_values=True)
    out = {k: v[0] for k, v in raw.items()}
    if "port" in out:
        try:
            out["port"] = int(out["port"])
        except ValueError:
            pass
    if "wss" in out:
        out["wss"] = out["wss"] in ("1", "true", "True")
    if "mode" in out:
        out["mode"] = envelope.normalize_auth_mode(out["mode"])
    if "key_mode" in out:
        out["key_mode"] = envelope.normalize_key_mode(out["key_mode"])
    return out


def pairing_uri_from_config(cfg: dict, *, host: Optional[str] = None,
                            wss: bool = False,
                            identity: Optional[str] = None) -> str:
    """Build the pairing URI straight from a broker config dict.

    Pass `identity` (e.g. `"player:win-lobby-01"`) to mint a per-endpoint code
    in `derived` key_mode (§17.4): the URI then carries that endpoint's `dk`
    instead of the PSK. Without an identity in derived mode the URI is
    discovery-only (no key) — call `device_pairing_uri` for a concrete endpoint.
    """
    mode = envelope.normalize_auth_mode(cfg.get("auth_mode"))
    key_mode = envelope.normalize_key_mode(cfg.get("key_mode"))
    return build_pairing_uri(
        host=host or cfg.get("advertise_host") or local_ip(),
        port=int(cfg.get("ws_port", 8770)),
        group=cfg.get("pair_group", "default"),
        mode=mode,
        psk=cfg.get("psk"),
        wss=wss,
        name=cfg.get("pair_name"),
        key_mode=key_mode,
        identity=identity,
    )


def device_pairing_uri(cfg: dict, identity: str, *,
                       host: Optional[str] = None, wss: bool = False,
                       name: Optional[str] = None) -> str:
    """Mint a pairing URI for one concrete endpoint `identity` (§17.4).

    `identity` is the endpoint's full `from` string verbatim — e.g.
    `"player:win-lobby-01"` or `"controller:phone-jay"`. In `derived` key_mode
    the URI carries that endpoint's `dk` (= HMAC(PSK, identity) hex) + `id`, so
    the endpoint receives only its own device_key and never the PSK. In `global`
    key_mode it falls back to the shared-PSK URI (backward compat).
    """
    mode = envelope.normalize_auth_mode(cfg.get("auth_mode"))
    key_mode = envelope.normalize_key_mode(cfg.get("key_mode"))
    return build_pairing_uri(
        host=host or cfg.get("advertise_host") or local_ip(),
        port=int(cfg.get("ws_port", 8770)),
        group=cfg.get("pair_group", "default"),
        mode=mode,
        psk=cfg.get("psk"),
        wss=wss,
        name=name if name is not None else cfg.get("pair_name"),
        key_mode=key_mode,
        identity=identity,
    )


def render_qr(uri: str) -> str:
    """Render the URI as a terminal QR code if `qrcode` is importable; else
    return the URI plus a note so an operator can still copy it (§15.2)."""
    try:
        import qrcode  # type: ignore
    except ImportError:
        return (f"{uri}\n"
                "(install the 'qrcode' package to render a scannable QR here)")
    qr = qrcode.QRCode(border=1)
    qr.add_data(uri)
    qr.make(fit=True)
    import io
    buf = io.StringIO()
    qr.print_ascii(out=buf, invert=True)
    return buf.getvalue().rstrip("\n") + "\n" + uri


def print_pairing(cfg: dict, *, host: Optional[str] = None, wss: bool = False,
                  out=None) -> str:
    """Build + print the pairing block on startup; returns the URI (§15.2)."""
    import sys
    out = out or sys.stdout
    uri = pairing_uri_from_config(cfg, host=host, wss=wss)
    mode = envelope.normalize_auth_mode(cfg.get("auth_mode"))
    key_mode = envelope.normalize_key_mode(cfg.get("key_mode"))
    print("\n=== LAN Media Wall — pairing (scan to onboard) ===", file=out)
    print(f"auth_mode={mode}  key_mode={key_mode}  "
          f"topology={cfg.get('topology', 'dedicated')}", file=out)
    if mode != envelope.AUTH_OPEN and key_mode == envelope.KEY_DERIVED:
        # In derived mode the per-endpoint key is minted per identity (§17.4):
        # this banner URI is discovery-only; use device_pairing_uri(cfg, id) to
        # mint a concrete endpoint's code carrying its own dk.
        print("note: derived key_mode — per-device codes carry that device's "
              "dk; this code is discovery-only (no key).", file=out)
    print(render_qr(uri), file=out)
    print("=" * 50 + "\n", file=out)
    return uri
