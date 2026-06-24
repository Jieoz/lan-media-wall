"""Auth-mode adaptivity (protocol §13): sign/verify gating + AuthState."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import auth as A  # noqa: E402

REAL_PSK = "a-real-32-byte-preshared-key-0123456789"


def test_normalize_mode_valid_and_fallback():
    assert A.normalize_mode("open") == "open"
    assert A.normalize_mode("OPTIONAL") == "optional"
    assert A.normalize_mode("  required ") == "required"
    # unknown / wrong type → default (open)
    assert A.normalize_mode("nonsense") == "open"
    assert A.normalize_mode(None) == "open"
    assert A.normalize_mode(123) == "open"


def test_has_usable_psk():
    assert A.has_usable_psk(REAL_PSK) is True
    assert A.has_usable_psk("") is False
    assert A.has_usable_psk("CHANGE_ME_32_BYTE_RANDOM_PRESHARED_KEY") is False
    assert A.has_usable_psk(None) is False


def test_should_sign_per_mode():
    # open: never sign, regardless of PSK
    assert A.should_sign("open", True) is False
    assert A.should_sign("open", False) is False
    # optional: sign only with a PSK
    assert A.should_sign("optional", True) is True
    assert A.should_sign("optional", False) is False
    # required: always sign
    assert A.should_sign("required", True) is True
    assert A.should_sign("required", False) is True


def test_should_verify_per_mode():
    # open: never verify
    assert A.should_verify("open", "deadbeef") is False
    assert A.should_verify("open", "") is False
    # optional: verify only when sig present
    assert A.should_verify("optional", "deadbeef") is True
    assert A.should_verify("optional", "") is False
    # required: always verify
    assert A.should_verify("required", "deadbeef") is True
    assert A.should_verify("required", "") is True


def test_can_operate_only_blocks_required_without_psk():
    ok, reason = A.can_operate("required", False)
    assert ok is False and reason == "needs PSK"
    assert A.can_operate("required", True) == (True, "")
    assert A.can_operate("open", False) == (True, "")
    assert A.can_operate("optional", False) == (True, "")


def test_authstate_open_no_psk_does_not_sign_and_can_operate():
    st = A.AuthState("open", "")
    assert st.should_sign() is False
    assert st.can_operate() == (True, "")
    assert st.should_verify("anything") is False


def test_authstate_required_no_psk_is_soft_error():
    st = A.AuthState("required", "")          # no usable PSK
    assert st.has_psk is False
    ok, reason = st.can_operate()
    assert ok is False and reason == "needs PSK"
    # it still *would* sign if asked (required) — caller gates on can_operate
    assert st.should_sign() is True


def test_authstate_adopt_changes_mode():
    st = A.AuthState("open", REAL_PSK)
    assert st.mode == "open"
    assert st.adopt("required") is True
    assert st.mode == "required"
    # re-adopting same mode → no change
    assert st.adopt("required") is False
    # None leaves mode untouched (coordinator didn't declare one)
    assert st.adopt(None) is False
    assert st.mode == "required"


def test_authstate_optional_signs_only_with_psk():
    with_psk = A.AuthState("optional", REAL_PSK)
    assert with_psk.should_sign() is True
    without = A.AuthState("optional", "")
    assert without.should_sign() is False
    # optional verify gates on inbound sig presence
    assert with_psk.should_verify("") is False
    assert with_psk.should_verify("sig") is True
