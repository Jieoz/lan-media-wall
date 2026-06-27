"""§17.4 pairing URI in derived key_mode + Hub receive-path with derived keys.

Asserts the QR carries the per-endpoint device_key (`dk`) + `id` and NEVER the
PSK, that key_mode is declared, that global mode still ships the PSK, and that
the broker's inbound gate accepts a correctly-derived frame but drops a frame
forged with a different identity's key (leak isolation through the Hub).
"""
import asyncio
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import broker as broker_mod  # noqa: E402
import envelope  # noqa: E402
import pairing  # noqa: E402

PSK = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


# ---- pairing URI: derived carries dk+id, never psk (§17.4) ---------------
def test_derived_uri_carries_dk_and_id_not_psk():
    ident = "player:win-lobby-01"
    uri = pairing.build_pairing_uri(
        host="192.168.1.10", port=8770, group="lobby", mode="required",
        psk=PSK, key_mode="derived", identity=ident)
    d = pairing.parse_pairing_uri(uri)
    assert d["key_mode"] == "derived"
    assert "psk" not in d                       # §17.4: PSK never leaves broker
    assert "psk=" not in uri
    assert d["id"] == ident
    # dk is exactly the hex of the endpoint's device_key.
    assert d["dk"] == envelope.derive_key(PSK, ident).hex()


def test_derived_uri_dk_is_per_endpoint():
    a = pairing.parse_pairing_uri(pairing.build_pairing_uri(
        host="h", mode="required", psk=PSK, key_mode="derived",
        identity="player:a"))
    b = pairing.parse_pairing_uri(pairing.build_pairing_uri(
        host="h", mode="required", psk=PSK, key_mode="derived",
        identity="player:b"))
    assert a["dk"] != b["dk"]


def test_global_uri_still_ships_psk():
    uri = pairing.build_pairing_uri(
        host="h", mode="required", psk=PSK, key_mode="global")
    d = pairing.parse_pairing_uri(uri)
    assert d["key_mode"] == "global"
    assert d["psk"] == PSK
    assert "dk" not in d


def test_open_mode_carries_no_key_even_in_derived():
    uri = pairing.build_pairing_uri(
        host="h", mode="open", psk=PSK, key_mode="derived",
        identity="player:a")
    assert "psk=" not in uri and "dk=" not in uri and "key_mode=" not in uri


def test_derived_without_identity_emits_no_key():
    # Discovery-only URI (no concrete endpoint) must not leak the PSK.
    uri = pairing.build_pairing_uri(
        host="h", mode="required", psk=PSK, key_mode="derived", identity=None)
    d = pairing.parse_pairing_uri(uri)
    assert d["key_mode"] == "derived"
    assert "psk" not in d and "dk" not in d


def test_device_pairing_uri_from_config():
    cfg = {"auth_mode": "required", "key_mode": "derived", "ws_port": 8770,
           "psk": PSK, "advertise_host": "192.168.1.10"}
    uri = pairing.device_pairing_uri(cfg, "controller:phone-jay")
    d = pairing.parse_pairing_uri(uri)
    assert d["dk"] == envelope.derive_key(PSK, "controller:phone-jay").hex()
    assert d["id"] == "controller:phone-jay"
    assert "psk" not in d


# ---- Hub receive-path with derived keys ----------------------------------
def _hub(**over):
    cfg = dict(broker_mod.DEFAULTS)
    cfg.update({
        "psk": PSK,
        "auth_mode": "required",
        "key_mode": "derived",
        "state_path": os.path.join(tempfile.mkdtemp(), "state.json"),
        "auth_fail_limit": 3,
    })
    cfg.update(over)
    cfg["auth_mode"] = envelope.normalize_auth_mode(cfg["auth_mode"])
    cfg["key_mode"] = envelope.normalize_key_mode(cfg["key_mode"])
    return broker_mod.Hub(cfg)


class FakeWS:
    def __init__(self):
        self.closed = None
        self.sent = []

    async def send(self, data):
        self.sent.append(data)

    async def close(self, code=1000, reason=""):
        self.closed = (code, reason)


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def test_hub_accepts_correctly_derived_hello():
    hub = _hub()
    conn = broker_mod.ClientConn(FakeWS(), "10.0.0.5")
    env = envelope.build_envelope(
        "hello", {"role": "player", "device_id": "p1", "group_id": "g"},
        "player:p1", "broker", PSK, key_mode="derived")
    run(hub._handle_text(conn, envelope.dumps(env), t2=envelope.now_ms()))
    assert conn.role == "player"
    assert "p1" in hub.players
    # The welcome the broker sent declares key_mode=derived (§17.3).
    welcome = envelope.parse(conn.ws.sent[0])
    assert welcome["payload"]["key_mode"] == "derived"
    # ...and is itself signed as from="broker" with the derived key.
    assert envelope.verify_sig(welcome, PSK, "derived")


def test_hub_rejects_frame_forged_with_other_identity_key():
    """Leak isolation through the Hub: a frame signed with player-A's key but
    claiming from=player-B must be dropped (§17.5)."""
    hub = _hub()
    conn = broker_mod.ClientConn(FakeWS(), "10.0.0.6")
    import hashlib
    import hmac as _hmac
    key_a = envelope.derive_key(PSK, "player:A")
    sstr = envelope.signing_string(
        1, "hello", "m1", envelope.now_ms(), "player:B", "broker",
        {"role": "player", "device_id": "B"}).encode("utf-8")
    forged = {
        "v": 1, "type": "hello", "msg_id": "m1", "ts": envelope.now_ms(),
        "from": "player:B", "to": "broker",
        "sig": _hmac.new(key_a, sstr, hashlib.sha256).hexdigest(),
        "payload": {"role": "player", "device_id": "B"},
    }
    run(hub._handle_text(conn, envelope.dumps(forged), t2=envelope.now_ms()))
    assert conn.role is None                    # never registered
    assert "B" not in hub.players
    assert conn.auth_fails >= 1                  # counted as an auth failure


def test_hub_global_key_mode_still_works():
    hub = _hub(key_mode="global")
    conn = broker_mod.ClientConn(FakeWS(), "10.0.0.7")
    env = envelope.build_envelope(
        "hello", {"role": "player", "device_id": "g1"},
        "player:g1", "broker", PSK, key_mode="global")
    run(hub._handle_text(conn, envelope.dumps(env), t2=envelope.now_ms()))
    assert "g1" in hub.players
