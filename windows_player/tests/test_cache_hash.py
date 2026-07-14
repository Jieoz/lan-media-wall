"""Canonical semantic playlist hash (protocol_spec §3.1 / group_playlist_hash_v1).

The hash is the cross-language adoption/consistency key: two playlists hash equal
iff their *playback semantics* match — ordered items (url / sha256 / duration /
per-item loop), plus playlist-level ``sync`` and ``loop_mode``. It deliberately
EXCLUDES ``playlist_id`` and ``push_id`` (both reusable / per-replace identity),
so a controller can tell "same content, different generation" from "divergent".

These tests pin the exact hex for a frozen fixture; the Kotlin suite pins the
SAME hex against the SAME fixture (CacheHashTest.kt) — that identity is the
cross-language contract.
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import cache_hash as H  # noqa: E402

FIXTURE = os.path.join(os.path.dirname(__file__), "fixtures",
                       "playlist_canonical.json")

# Pinned cross-language expected hash for fixtures/playlist_canonical.json.
# The Kotlin test asserts this identical value. If the canonical rule changes,
# both must change together.
EXPECTED_HEX = "9a5fe39de03984139f34a1127fb7ba9edfbdd6fce582d3417e3e550a1ffec072"


def _load_fixture():
    with open(FIXTURE, encoding="utf-8") as f:
        return json.load(f)


def test_canonical_string_shape():
    pl = _load_fixture()
    canon = H.canonical_playlist_string(pl)
    # deterministic, records newline-joined, version-tagged
    assert canon.startswith("lmw-playlist-hash-v1\n")
    assert "loop_mode=all" in canon
    assert "sync=true" in canon
    # playlist_id / push_id never leak into the canonical form
    assert "pl-frozen-001" not in canon
    assert "push-should-not-count" not in canon


def test_hash_is_sha256_of_canonical():
    pl = _load_fixture()
    canon = H.canonical_playlist_string(pl)
    assert H.canonical_playlist_hash(pl) == \
        hashlib.sha256(canon.encode("utf-8")).hexdigest()


def test_hash_matches_pinned_cross_language_value():
    pl = _load_fixture()
    assert H.canonical_playlist_hash(pl) == EXPECTED_HEX


def test_playlist_id_and_push_id_do_not_affect_hash():
    pl = _load_fixture()
    base = H.canonical_playlist_hash(pl)
    pl2 = dict(pl)
    pl2["playlist_id"] = "totally-different-id"
    pl2["push_id"] = "another-push"
    assert H.canonical_playlist_hash(pl2) == base


def test_item_order_changes_hash():
    pl = _load_fixture()
    base = H.canonical_playlist_hash(pl)
    pl2 = dict(pl)
    pl2["items"] = list(reversed(pl["items"]))
    assert H.canonical_playlist_hash(pl2) != base


def test_loop_mode_change_changes_hash():
    pl = _load_fixture()
    base = H.canonical_playlist_hash(pl)
    pl2 = dict(pl, loop_mode="none")
    assert H.canonical_playlist_hash(pl2) != base


def test_legacy_loop_bool_folds_into_loop_mode():
    # A legacy playlist with only `loop:true` (no loop_mode) must hash equal to
    # the same content declared loop_mode=all — the §6.3 single fold point.
    a = {"sync": True, "loop": True, "items": [
        {"url": "http://h/x.mp4", "sha256": "AA", "duration_ms": 1000}]}
    b = {"sync": True, "loop_mode": "all", "items": [
        {"url": "http://h/x.mp4", "sha256": "aa", "duration_ms": 1000}]}
    assert H.canonical_playlist_hash(a) == H.canonical_playlist_hash(b)


def test_missing_duration_and_sha_normalize():
    pl = {"sync": False, "loop_mode": "none", "items": [
        {"url": "http://h/y.mp4"}]}
    # must not raise; produces a stable hash
    h1 = H.canonical_playlist_hash(pl)
    h2 = H.canonical_playlist_hash(pl)
    assert h1 == h2 and len(h1) == 64


def test_empty_playlist_is_stable():
    pl = {"sync": True, "loop_mode": "none", "items": []}
    assert len(H.canonical_playlist_hash(pl)) == 64
