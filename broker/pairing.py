"""Zero-config pairing URI + QR (§15).

Builds the `lmw://pair?...` URI from the running broker's config so an operator
can scan it (or copy it) to onboard endpoints without hand-typing host/port/
group/mode/psk. Pure client-side capability — it touches no WS frame (§15.2).

URI shape (§15.1):

    lmw://pair?host=<ip>&port=<8770>&group=<gid>&mode=<open|optional|required>
              &psk=<hex?>&wss=<0|1>&name=<optional preset name>

- `open` mode omits `psk` entirely (pure "scan to join", §15.1).
- `required`/`optional` include the §3 PSK (hex) — the QR is the entry ticket.
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
                      wss: bool = False, name: Optional[str] = None) -> str:
    """Assemble the `lmw://pair?...` URI (§15.1).

    `psk` is included only in `optional`/`required` modes and only when present;
    in `open` mode it is always omitted regardless of what was passed in.
    """
    mode = envelope.normalize_auth_mode(mode)
    parts = [
        ("host", host),
        ("port", str(port)),
        ("group", group),
        ("mode", mode),
        ("wss", "1" if wss else "0"),
    ]
    if mode != envelope.AUTH_OPEN and psk:
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
    return out


def pairing_uri_from_config(cfg: dict, *, host: Optional[str] = None,
                            wss: bool = False) -> str:
    """Build the pairing URI straight from a broker config dict."""
    mode = envelope.normalize_auth_mode(cfg.get("auth_mode"))
    return build_pairing_uri(
        host=host or cfg.get("advertise_host") or local_ip(),
        port=int(cfg.get("ws_port", 8770)),
        group=cfg.get("pair_group", "default"),
        mode=mode,
        psk=cfg.get("psk"),
        wss=wss,
        name=cfg.get("pair_name"),
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
    print("\n=== LAN Media Wall — pairing (scan to onboard) ===", file=out)
    print(f"auth_mode={mode}  topology={cfg.get('topology', 'dedicated')}",
          file=out)
    print(render_qr(uri), file=out)
    print("=" * 50 + "\n", file=out)
    return uri
