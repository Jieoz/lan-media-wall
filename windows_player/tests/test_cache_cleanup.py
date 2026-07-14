"""CacheCleanup — proven-safe cleanup core (design §3.2 / §4.2).

Behaviour matrix (mirrored by Kotlin CacheCleanupTest.kt):
  - active/prepared/playing/last_task/inflight/pinned cannot be deleted;
  - shared blob (one sha, many item ids) survives while any ref is protected;
  - historical playlist metadata alone never pins media;
  - dry-run reports candidates but mutates neither disk nor index;
  - selected mode accepts item ids, never paths;
  - not_found / delete_failed / protected reasons are distinct;
  - expected_push_id mismatch fails the whole op closed (deletes nothing);
  - generation change between plan and commit invalidates the op;
  - repeated request_id does not delete twice (returns original result);
  - success prunes the index and updates the cache summary.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import cache_cleanup as C  # noqa: E402
import cache_refs as R  # noqa: E402


# --- fake backend --------------------------------------------------------
def item(item_id, sha=None):
    return {"item_id": item_id, "sha256": sha, "name": f"{item_id}.mp4",
            "url": f"http://h/{item_id}.mp4"}


def content_key_of(it):
    sha = it.get("sha256")
    return f"sha256:{sha.lower()}" if sha else f"path:{it['item_id']}"


class FakeBackend:
    """In-memory stand-in for Downloader+state; records physical effects."""

    def __init__(self, inventory, *, active=None, prepared=None, playing=None,
                 resume=None, inflight=None, pinned=None, push_id="push-1",
                 missing=None, delete_fail=None):
        self._inventory = inventory
        self._active = active or []
        self._prepared = prepared or []
        self._playing = playing
        self._resume = resume or []
        self._inflight = inflight or []
        self._pinned = pinned or []
        self._push_id = push_id
        # content_key -> bytes on "disk"
        self._sizes = {}
        for it in inventory:
            self._sizes[content_key_of(it)] = 1000
        for k in (missing or []):
            self._sizes.pop(k, None)  # simulate already-gone files
        self._delete_fail = set(delete_fail or [])  # content_keys that fail
        self.deleted_keys = []          # physical deletes actually performed
        self.pruned_index = []          # index entries pruned
        self.push_id_reads = 0

    # --- CacheBackend protocol ---
    def content_key_of(self, it):
        return content_key_of(it)

    def build_snapshot(self):
        return R.CacheReferenceSnapshot.build(
            content_key_of=content_key_of,
            inventory=self._inventory,
            active_items=self._active,
            prepared_items=self._prepared,
            playing_item=self._playing,
            resume_items=self._resume,
            inflight_items=self._inflight,
            pinned_items=self._pinned,
        )

    def inventory(self):
        return list(self._inventory)

    def size_of(self, content_key):
        return self._sizes.get(content_key)

    def current_push_id(self):
        self.push_id_reads += 1
        return self._push_id

    def delete(self, content_key):
        if content_key in self._delete_fail:
            return False
        if content_key not in self._sizes:
            return False
        self._sizes.pop(content_key, None)
        self.deleted_keys.append(content_key)
        return True

    def prune_index(self, item_ids):
        self.pruned_index.extend(item_ids)

    def summary(self):
        total = sum(self._sizes.values())
        return {"ready_items": len(self._sizes), "total_bytes": total,
                "reclaimable_bytes": 0}


def cleanup(backend):
    return C.CacheCleanup(backend)


def req(request_id="r1", mode="unreferenced", item_ids=None, dry_run=False,
        expected_push_id=None, reason="manual"):
    return C.CleanupRequest(request_id=request_id, mode=mode,
                            item_ids=item_ids, dry_run=dry_run,
                            expected_push_id=expected_push_id, reason=reason)


# --- protection matrix ---------------------------------------------------
def test_active_cannot_be_deleted():
    a, h = item("a", "AA"), item("h", "HH")
    be = FakeBackend([a, h], active=[a])
    res = cleanup(be).run(req())
    assert be.deleted_keys == [content_key_of(h)]
    skipped = {s["item_id"]: s["reason"] for s in res["skipped"]}
    assert skipped["a"] == R.ACTIVE
    assert any(d["item_id"] == "h" for d in res["deleted"])


def test_prepared_cannot_be_deleted():
    a = item("a", "AA")
    be = FakeBackend([a], prepared=[a])
    res = cleanup(be).run(req())
    assert be.deleted_keys == []
    assert res["skipped"][0]["reason"] == R.PREPARED


def test_playing_cannot_be_deleted():
    a = item("a", "AA")
    be = FakeBackend([a], playing=a)
    res = cleanup(be).run(req())
    assert be.deleted_keys == []
    assert res["skipped"][0]["reason"] == R.PLAYING


def test_last_task_cannot_be_deleted():
    a = item("a", "AA")
    be = FakeBackend([a], resume=[a])
    res = cleanup(be).run(req())
    assert be.deleted_keys == []
    assert res["skipped"][0]["reason"] == R.LAST_TASK


def test_inflight_cannot_be_deleted():
    a = item("a", "AA")
    be = FakeBackend([a], inflight=[a])
    res = cleanup(be).run(req())
    assert be.deleted_keys == []
    assert res["skipped"][0]["reason"] == R.INFLIGHT


def test_pinned_cannot_be_deleted():
    a = item("a", "AA")
    be = FakeBackend([a], pinned=[a])
    res = cleanup(be).run(req())
    assert be.deleted_keys == []
    assert res["skipped"][0]["reason"] == R.PINNED


def test_shared_blob_not_deleted_while_any_ref_protected():
    a = item("a", "DEAD")
    b = item("b", "dead")  # same physical blob, different id
    be = FakeBackend([a, b], active=[a])
    res = cleanup(be).run(req())
    assert be.deleted_keys == []  # blob protected by a → b's request skipped
    reasons = {s["item_id"]: s["reason"] for s in res["skipped"]}
    assert reasons["a"] == R.ACTIVE
    assert reasons["b"] == R.SHARED_CONTENT


def test_playlist_history_alone_is_reclaimable():
    old = item("old", "0LD")
    be = FakeBackend([old])  # only in inventory, nothing live references it
    res = cleanup(be).run(req())
    assert be.deleted_keys == [content_key_of(old)]
    assert res["deleted"][0]["item_id"] == "old"
    assert res["freed_bytes"] == 1000


# --- dry-run -------------------------------------------------------------
def test_dry_run_reports_candidates_without_mutating():
    a, h = item("a", "AA"), item("h", "HH")
    be = FakeBackend([a, h], active=[a])
    res = cleanup(be).run(req(dry_run=True))
    assert res["dry_run"] is True
    assert be.deleted_keys == [] and be.pruned_index == []
    # candidate reported as would-delete with its freed bytes
    assert any(d["item_id"] == "h" for d in res["deleted"])
    assert res["freed_bytes"] == 1000
    # summary unchanged in dry-run
    assert res["summary_after"]["ready_items"] == 2


# --- selected mode -------------------------------------------------------
def test_selected_mode_targets_only_given_item_ids():
    a, b, c = item("a", "AA"), item("b", "BB"), item("c", "CC")
    be = FakeBackend([a, b, c])
    res = cleanup(be).run(req(mode="selected", item_ids=["b"]))
    assert be.deleted_keys == [content_key_of(b)]
    assert [d["item_id"] for d in res["deleted"]] == ["b"]


def test_selected_unknown_id_is_not_found():
    a = item("a", "AA")
    be = FakeBackend([a])
    res = cleanup(be).run(req(mode="selected", item_ids=["ghost"]))
    assert be.deleted_keys == []
    assert res["skipped"][0]["reason"] == R.NOT_FOUND


# --- dangling-alias invariant (selected mode, shared blob) --------------
def test_selected_one_alias_prunes_all_aliases_of_shared_blob():
    # a1 and a2 are two DIFFERENT item ids that resolve to the SAME physical
    # blob (same sha). Neither is protected. A selected cleanup names only a1.
    a1 = item("a1", "DEAD")
    a2 = item("a2", "dead")  # same content_key as a1
    be = FakeBackend([a1, a2])
    res = cleanup(be).run(req(mode="selected", item_ids=["a1"]))

    # (2) the shared physical blob is deleted exactly once
    assert be.deleted_keys == [content_key_of(a1)]
    assert len(be.deleted_keys) == 1
    # (3) BOTH alias ids are pruned from the index — no dangling row for a2
    assert sorted(be.pruned_index) == ["a1", "a2"]
    # (4) the response honestly reports only the requested candidate id
    assert [d["item_id"] for d in res["deleted"]] == ["a1"]
    # one-byte-count-per-blob preserved
    assert res["freed_bytes"] == 1000


def test_selected_duplicate_id_deletes_and_prunes_once():
    a = item("a", "AA")
    be = FakeBackend([a])
    res = cleanup(be).run(req(mode="selected", item_ids=["a", "a", "a"]))
    assert be.deleted_keys == [content_key_of(a)]      # deleted once
    assert be.pruned_index == ["a"]                     # pruned once
    assert [d["item_id"] for d in res["deleted"]] == ["a"]  # reported once
    assert res["freed_bytes"] == 1000


def test_unreferenced_mode_prunes_every_alias_of_reclaimed_blob():
    # two unreferenced aliases sharing one blob; unreferenced sweep reclaims it.
    a1 = item("a1", "F00D")
    a2 = item("a2", "f00d")
    be = FakeBackend([a1, a2])
    res = cleanup(be).run(req())  # unreferenced mode
    assert be.deleted_keys == [content_key_of(a1)]      # one physical delete
    assert sorted(be.pruned_index) == ["a1", "a2"]      # both aliases pruned
    assert res["freed_bytes"] == 1000                   # counted once


def test_dry_run_shared_alias_prunes_nothing():
    a1, a2 = item("a1", "DEAD"), item("a2", "dead")
    be = FakeBackend([a1, a2])
    res = cleanup(be).run(req(mode="selected", item_ids=["a1"], dry_run=True))
    assert be.deleted_keys == [] and be.pruned_index == []  # nothing mutated
    assert [d["item_id"] for d in res["deleted"]] == ["a1"]  # candidate only


def test_delete_failure_shared_alias_prunes_nothing():
    a1, a2 = item("a1", "DEAD"), item("a2", "dead")
    be = FakeBackend([a1, a2], delete_fail=[content_key_of(a1)])
    res = cleanup(be).run(req(mode="selected", item_ids=["a1"]))
    assert be.deleted_keys == []          # physical delete failed
    assert be.pruned_index == []          # so NO alias is pruned
    assert res["failed"][0]["item_id"] == "a1"
    assert res["failed"][0]["reason"] == C.DELETE_FAILED


# --- distinct failure reasons -------------------------------------------
def test_missing_file_reports_not_found_not_delete_failed():
    a = item("a", "AA")
    be = FakeBackend([a], missing=[content_key_of(a)])
    res = cleanup(be).run(req())
    assert be.deleted_keys == []
    assert res["skipped"][0]["reason"] == R.NOT_FOUND
    assert res["failed"] == []


def test_delete_failure_reports_delete_failed():
    a = item("a", "AA")
    be = FakeBackend([a], delete_fail=[content_key_of(a)])
    res = cleanup(be).run(req())
    assert res["failed"][0]["item_id"] == "a"
    assert res["failed"][0]["reason"] == C.DELETE_FAILED
    assert res["deleted"] == []


# --- generation protection ----------------------------------------------
def test_expected_push_mismatch_fails_closed():
    a = item("a", "AA")
    be = FakeBackend([a], push_id="push-current")
    res = cleanup(be).run(req(expected_push_id="push-STALE"))
    assert res["ok"] is False
    assert res["error"] == C.GENERATION_MISMATCH
    assert be.deleted_keys == []  # nothing deleted


def test_generation_change_between_plan_and_commit_aborts():
    a, h = item("a", "AA"), item("h", "HH")
    be = FakeBackend([a, h], active=[a], push_id="push-1")

    # inject a generation change after planning, before commit deletes
    orig_plan = C.CacheCleanup._plan

    def racing_plan(self, request, snapshot):
        out = orig_plan(self, request, snapshot)
        be._push_id = "push-2"  # generation moved under us
        return out

    C.CacheCleanup._plan = racing_plan
    try:
        res = cleanup(be).run(req(expected_push_id="push-1"))
    finally:
        C.CacheCleanup._plan = orig_plan
    assert res["ok"] is False
    assert res["error"] == C.GENERATION_CHANGED
    assert be.deleted_keys == []  # fail-closed, nothing stale deleted


# --- idempotency ---------------------------------------------------------
def test_repeated_request_id_does_not_delete_twice():
    h = item("h", "HH")
    be = FakeBackend([h])
    cl = cleanup(be)
    first = cl.run(req(request_id="dup"))
    assert be.deleted_keys == [content_key_of(h)]
    # second call, same request_id: returns original terminal result, no re-delete
    second = cl.run(req(request_id="dup"))
    assert be.deleted_keys == [content_key_of(h)]  # still one delete
    assert second.get("idempotent_replay") is True
    # substance identical to the original terminal result (bar the replay marker)
    assert {k: v for k, v in second.items() if k != "idempotent_replay"} == first


def test_dry_run_is_not_journaled_as_terminal():
    h = item("h", "HH")
    be = FakeBackend([h])
    cl = cleanup(be)
    cl.run(req(request_id="dr", dry_run=True))
    # a later commit with a fresh id still deletes (dry-run didn't consume state)
    cl.run(req(request_id="commit1"))
    assert be.deleted_keys == [content_key_of(h)]


# --- index + summary consistency ----------------------------------------
def test_success_prunes_index_and_updates_summary():
    a, h = item("a", "AA"), item("h", "HH")
    be = FakeBackend([a, h], active=[a])
    res = cleanup(be).run(req())
    assert "h" in be.pruned_index
    assert res["summary_after"]["ready_items"] == 1  # only 'a' remains
    assert res["observed_push_id"] == "push-1"
