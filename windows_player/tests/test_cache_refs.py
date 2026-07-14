"""CacheReferenceSnapshot — the player-local protection union (design §4.1).

The player is the ONLY authority on physical deletion. Deletion is keyed by
*content* (``content_key`` = sha256 when known, else the normalized target path),
never by a remote-supplied path. A content blob is protected while ANY item that
references it is protected. The protection union covers: active playlist, prepared
generation, currently playing source, resume/last_task, in-flight/verify/.part,
and explicit pins. Shared content is protected transitively.

This snapshot is a pure model (no Downloader, no disk) so the whole protection
union is unit-testable. The Kotlin `CacheReferenceSnapshot.kt` mirrors it.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import cache_refs as R  # noqa: E402


def item(item_id, sha=None, url=None):
    return {"item_id": item_id, "sha256": sha,
            "url": url or f"http://h/{item_id}.mp4", "name": f"{item_id}.mp4"}


def _key(it):
    """Content key resolver used by the tests: sha256 else item_id-as-path."""
    sha = it.get("sha256")
    return f"sha256:{sha.lower()}" if sha else f"path:{it['item_id']}"


def build(**kw):
    return R.CacheReferenceSnapshot.build(content_key_of=_key, **kw)


def test_active_playlist_content_is_protected():
    a = item("a", sha="AA")
    snap = build(inventory=[a], active_items=[a])
    ck = snap.content_key_for("a")
    assert snap.is_protected(ck)
    kind, reason = snap.classify_item("a")
    assert kind == "direct" and reason == R.ACTIVE


def test_prepared_source_is_protected():
    a = item("a", sha="AA")
    snap = build(inventory=[a], prepared_items=[a])
    assert snap.classify_item("a") == ("direct", R.PREPARED)


def test_playing_source_is_protected():
    a = item("a", sha="AA")
    snap = build(inventory=[a], playing_item=a)
    assert snap.classify_item("a") == ("direct", R.PLAYING)


def test_last_task_resume_source_is_protected():
    a = item("a", sha="AA")
    snap = build(inventory=[a], resume_items=[a])
    assert snap.classify_item("a") == ("direct", R.LAST_TASK)


def test_inflight_source_is_protected():
    a = item("a", sha="AA")
    snap = build(inventory=[a], inflight_items=[a])
    assert snap.classify_item("a") == ("direct", R.INFLIGHT)


def test_pinned_source_is_protected():
    a = item("a", sha="AA")
    snap = build(inventory=[a], pinned_items=[a])
    assert snap.classify_item("a") == ("direct", R.PINNED)


def test_unreferenced_item_is_deletable():
    a = item("a", sha="AA")
    hist = item("h", sha="HH")  # only in inventory (history), no protection
    snap = build(inventory=[a, hist], active_items=[a])
    assert snap.classify_item("h") == (None, None)
    assert not snap.is_protected(snap.content_key_for("h"))


def test_shared_blob_protects_all_item_ids():
    # two DIFFERENT item ids share one sha (same physical file). Only one is
    # active; the other must be protected transitively as shared_content.
    a = item("a", sha="DEAD")
    b = item("b", sha="dead")  # same blob, different id, different hex case
    snap = build(inventory=[a, b], active_items=[a])
    assert snap.content_key_for("a") == snap.content_key_for("b")
    # a is directly active; b is protected because it shares a's blob
    assert snap.classify_item("a") == ("direct", R.ACTIVE)
    assert snap.classify_item("b") == ("shared", R.SHARED_CONTENT)


def test_playlist_history_alone_does_not_protect_media():
    # ROOT-CAUSE FIX: a blob that appears only in historical playlist metadata
    # (never active/prepared/playing/resume/inflight/pinned) is reclaimable.
    old = item("old", sha="0LD")
    snap = build(inventory=[old])  # present on disk, referenced by nothing live
    assert snap.classify_item("old") == (None, None)


def test_direct_reason_precedence_playing_over_active():
    a = item("a", sha="AA")
    snap = build(inventory=[a], active_items=[a], playing_item=a)
    # playing is the most specific/urgent reason
    assert snap.classify_item("a") == ("direct", R.PLAYING)


def test_unknown_item_classifies_as_not_found():
    snap = build(inventory=[])
    assert snap.classify_item("ghost") == (None, R.NOT_FOUND)
    assert snap.content_key_for("ghost") is None
