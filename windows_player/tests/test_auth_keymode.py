"""§17 AuthState key-mode adaptivity + sign/verify key resolution."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import auth as A  # noqa: E402
import envelope as E  # noqa: E402

PSK = "a-real-32-byte-preshared-key-0123456789"


def test_normalize_key_mode_valid_and_fallback():
    assert A.normalize_key_mode("global") == "global"
    assert A.normalize_key_mode("DERIVED") == "derived"
    assert A.normalize_key_mode("  derived ") == "derived"
    # missing / unknown / wrong type → global (v1.2 backward compat)
    assert A.normalize_key_mode("nonsense") == "global"
    assert A.normalize_key_mode(None) == "global"
    assert A.normalize_key_mode(123) == "global"


def test_authstate_defaults_to_global():
    st = A.AuthState("required", PSK)
    assert st.key_mode == "global"
    assert st.sign_kwargs() == {}            # global → key=PSK
    assert st.verify_resolver() is None
    assert st.verify_key_mode() == "global"


def test_authstate_adopt_key_mode_changes_and_is_idempotent():
    st = A.AuthState("required", PSK)
    assert st.adopt_key_mode("derived") is True
    assert st.key_mode == "derived"
    assert st.adopt_key_mode("derived") is False
    # None leaves it untouched (coordinator didn't declare one)
    assert st.adopt_key_mode(None) is False
    assert st.key_mode == "derived"


def test_coordinator_with_psk_derives_on_the_fly_no_resolver():
    # holds PSK + derived → verify by deriving per-`from`; no resolver, key_mode
    # passed through.
    st = A.AuthState("required", PSK, key_mode="derived",
                     identity="player:win-1")
    assert st.verify_resolver() is None
    assert st.verify_key_mode() == "derived"
    # signs in derived mode by deriving from its own identity (it has the PSK)
    assert st.sign_kwargs() == {"key_mode": "derived"}


def test_pskless_end_signs_with_device_key_and_resolves_verify():
    dk = E.derive_device_key(PSK, "player:win-1")
    bk = E.derive_device_key(PSK, "broker")
    st = A.AuthState("required", "", key_mode="derived",
                     identity="player:win-1", device_key=dk,
                     verify_keys={"broker": bk})
    # signs with our device_key
    assert st.sign_kwargs() == {"key_mode": "derived", "device_key": dk}
    # PSK-less → uses a resolver for inbound verification
    resolver = st.verify_resolver()
    assert resolver is not None
    assert resolver("broker") == bk
    assert resolver("player:other") is None  # no key → fail closed


def test_pskless_derived_end_can_operate_in_required():
    # §17.4: a paired, PSK-less end in required mode is NOT a soft error — it
    # signs with its device_key.
    dk = E.derive_device_key(PSK, "player:win-1")
    st = A.AuthState("required", "", key_mode="derived",
                     identity="player:win-1", device_key=dk)
    assert st.has_key_material is True
    assert st.can_operate() == (True, "")
    assert st.should_sign() is True


def test_required_no_psk_no_device_key_is_soft_error():
    st = A.AuthState("required", "", key_mode="derived",
                     identity="player:win-1")  # no device_key, no PSK
    assert st.has_key_material is False
    ok, reason = st.can_operate()
    assert ok is False and reason == "needs PSK"


def test_optional_signs_only_with_material_in_derived():
    dk = E.derive_device_key(PSK, "player:win-1")
    with_dk = A.AuthState("optional", "", key_mode="derived",
                          identity="player:win-1", device_key=dk)
    assert with_dk.should_sign() is True
    without = A.AuthState("optional", "", key_mode="derived",
                          identity="player:win-1")
    assert without.should_sign() is False


def test_end_to_end_pskless_player_to_broker_and_back():
    """Full §17 round trip with the player holding NO PSK: it signs outbound
    with its device_key (broker re-derives & accepts), and verifies the
    broker's reply with the broker_key from pairing."""
    dk = E.derive_device_key(PSK, "player:win-1")
    bk = E.derive_device_key(PSK, "broker")
    player = A.AuthState("required", "", key_mode="derived",
                         identity="player:win-1", device_key=dk,
                         verify_keys={"broker": bk})

    # outbound: player signs as itself
    out = E.build_envelope(player.psk, "status", "player:win-1", "broker",
                           {"state": "playing"},
                           sign_frame=player.should_sign(),
                           **player.sign_kwargs())
    # broker (holds PSK) verifies by deriving from `from`
    ok_b, _ = E.verify(PSK, out, now=out["ts"], key_mode="derived")
    assert ok_b is True

    # inbound: broker signs a command with its own key (it has the PSK)
    cmd = E.build_envelope(PSK, "play_at", "broker", "group:lobby",
                           {"url": "x"}, key_mode="derived")
    # player (no PSK) verifies via its resolver over the paired broker_key
    ok_p, _ = E.verify(player.psk, cmd, now=cmd["ts"],
                       key_mode=player.verify_key_mode(),
                       key_resolver=player.verify_resolver())
    assert ok_p is True

    # leak isolation: that same player can't forge a frame as player:other
    forged = E.build_envelope(player.psk, "status", "player:other", "broker",
                              {"x": 1}, sign_frame=True, **player.sign_kwargs())
    ok_f, reason_f = E.verify(PSK, forged, now=forged["ts"], key_mode="derived")
    assert ok_f is False and reason_f == "sig"
