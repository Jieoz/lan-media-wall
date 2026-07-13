"""Locks the durable expected-release-certificate wiring (§根因B).

The build/promote lanes must resolve ONE coherent expected signer fingerprint
from a checked-in canonical source (scripts/resolve_release_cert.sh), so the
release lane fails closed even when the optional ANDROID_RELEASE_CERT_SHA256
repository variable is unset — the field failure that made android-build's
"Prepare required release keystore" step abort. These tests would go RED if a
lane reverted to requiring the empty variable, or the canonical fingerprint
drifted from the documented one.
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOLVER = ROOT / "scripts" / "resolve_release_cert.sh"
CANONICAL = ROOT / "android_apps" / "player" / "release-cert-sha256.txt"
WORKFLOWS = ROOT / ".github" / "workflows"

# The fixed public production certificate (documented in the player README).
EXPECTED = "69EC70E592AED46C4EB1412FE7668F41514681101ACD0DD9DBB098D1E26D6D54"


def _canonical_value() -> str:
    for line in CANONICAL.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            return re.sub(r"[^0-9A-Fa-f]", "", s).upper()
    raise AssertionError("no fingerprint line in canonical file")


def test_canonical_file_holds_the_fixed_fingerprint() -> None:
    assert CANONICAL.is_file()
    assert _canonical_value() == EXPECTED


def test_resolver_emits_normalised_fingerprint_from_file() -> None:
    out = subprocess.run(
        ["bash", str(RESOLVER)],
        capture_output=True, text=True, cwd=ROOT,
        env={"PATH": "/usr/bin:/bin"},
    )
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == EXPECTED


def test_resolver_prefers_variable_override_when_valid() -> None:
    override = "aa" * 32
    out = subprocess.run(
        ["bash", str(RESOLVER)],
        capture_output=True, text=True, cwd=ROOT,
        env={"PATH": "/usr/bin:/bin", "ANDROID_RELEASE_CERT_SHA256": override},
    )
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == override.upper()


def _resolve(override: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(RESOLVER)],
        capture_output=True, text=True, cwd=ROOT,
        env={"PATH": "/usr/bin:/bin", "ANDROID_RELEASE_CERT_SHA256": override},
    )


def test_resolver_accepts_colon_delimited_keytool_form() -> None:
    # keytool prints fingerprints as colon-separated byte pairs; the resolver
    # must normalise that to bare uppercase hex, not reject it.
    colon = ":".join(EXPECTED[i:i + 2] for i in range(0, len(EXPECTED), 2))
    out = _resolve(colon)
    assert out.returncode == 0, out.stderr
    assert out.stdout.strip() == EXPECTED


def test_resolver_fails_closed_on_garbled_override() -> None:
    out = _resolve("not-a-real-cert")
    assert out.returncode != 0
    assert "::error::" in out.stderr


def test_resolver_fails_closed_on_junk_plus_valid_hex() -> None:
    # A 64-hex fingerprint smuggled in with arbitrary junk must NOT be silently
    # salvaged. The old `tr -cd '[:xdigit:]'` stripped the junk and accepted the
    # hex; the strict parser rejects the whole value fail-closed.
    out = _resolve("ZZZZ" + EXPECTED)
    assert out.returncode != 0
    assert "::error::" in out.stderr


def test_resolver_fails_closed_on_malformed_separators() -> None:
    # Non-colon separators (dashes) are not a recognised fingerprint form.
    dashed = "-".join(EXPECTED[i:i + 2] for i in range(0, len(EXPECTED), 2))
    out = _resolve(dashed)
    assert out.returncode != 0
    assert "::error::" in out.stderr


def test_signing_lanes_resolve_instead_of_requiring_empty_variable() -> None:
    for name in ("android-build.yml", "flutter-build.yml", "release-promote.yml"):
        text = (WORKFLOWS / name).read_text(encoding="utf-8")
        assert "scripts/resolve_release_cert.sh" in text, name
