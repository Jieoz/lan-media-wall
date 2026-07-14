"""Windows LIVE cache adapter + cache_cleanup / cache_inventory handlers (TB1).

Phase B: wires the proven-safe cleanup core (cache_cleanup.py / cache_refs.py)
into the REAL Player over the REAL Downloader + PersistentState, and dispatches
the two inbound message types to terminal, structured results.

Behaviour proven here (real adapter, not FakeBackend):
  - a live snapshot protects the currently-playing / active / prepared /
    last_task / inflight items and their shared blobs;
  - cache_cleanup with dry_run mutates nothing on disk;
  - cache_cleanup commit physically deletes the reclaimable blob only, prunes
    the downloader index, and emits ONE terminal cache_cleanup_result (never an
    optimistic generic ack);
  - a target that names another device does no work and emits nothing;
  - expected_push_id mismatch fails closed (deletes nothing);
  - cache_inventory returns per-item state + protection reasons;
  - the live backend produces a cache_summary shape for status.
"""
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config as C  # noqa: E402
import main as M  # noqa: E402
from downloader import CacheEntry  # noqa: E402


class _FakeWs:
    def __init__(self):
        self.sent = []

    async def send(self, type_, payload, to="broker", *, msg_id=None):
        self.sent.append((type_, payload))
        return "mid-1"


def _player(tmp_path, **cfg_over):
    raw = dict(C.DEFAULTS)
    raw["state_dir"] = str(tmp_path / "state")
    raw["cache_dir"] = str(tmp_path / "cache")
    raw.update(cfg_over)
    cfg = C.Config(raw=raw)
    p = M.Player(cfg)
    p.ws = _FakeWs()

    async def _fake_mpv(cmd, *a, **kw):
        return None

    p._mpv = _fake_mpv  # type: ignore[assignment]
    return p


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def _cache_file(p, item):
    """Materialize a fake cached blob on disk + a ready entry in the downloader,
    exactly as a completed download would leave it."""
    path = p.downloader.local_path(item)
    path.write_bytes(b"x" * 1000)
    p.downloader._entries[item["item_id"]] = CacheEntry(
        item_id=item["item_id"], state="ready", progress=100, path=path)
    return path


def _item(item_id, sha=None):
    return {"item_id": item_id, "type": "video", "name": f"{item_id}.mp4",
            "url": f"http://h/{item_id}.mp4", "sha256": sha}


def _playlist(pid, push_id, items, index=0):
    return {"playlist_id": pid, "push_id": push_id, "items": items}


# --- dispatch / no-optimistic-ack ---------------------------------------
def test_cache_cleanup_is_not_in_generic_ack_set(tmp_path):
    """The destructive command must NEVER receive an optimistic generic ack —
    only its own terminal cache_cleanup_result (E0001 truthfulness)."""
    p = _player(tmp_path)
    a = _item("a")
    _cache_file(p, a)
    _run(p._on_message("cache_cleanup",
                       {"device_id": p.device_id, "request_id": "r1",
                        "mode": "unreferenced"},
                       {"msg_id": "m1"}))
    kinds = [k for k, _ in p.ws.sent]
    assert "ack" not in kinds
    assert kinds == ["cache_cleanup_result"]


def test_target_mismatch_does_no_work_and_stays_silent(tmp_path):
    p = _player(tmp_path)
    a = _item("a")
    _cache_file(p, a)
    _run(p._on_message("cache_cleanup",
                       {"device_id": "some-other-device", "request_id": "r1",
                        "mode": "unreferenced"},
                       {"msg_id": "m1"}))
    assert p.ws.sent == []
    assert p.downloader.local_path(a).exists()  # untouched


# --- dry-run vs commit --------------------------------------------------
def test_dry_run_reports_candidate_but_deletes_nothing(tmp_path):
    p = _player(tmp_path)
    a = _item("a")
    path = _cache_file(p, a)
    _run(p._on_message("cache_cleanup",
                       {"device_id": p.device_id, "request_id": "r1",
                        "mode": "unreferenced", "dry_run": True},
                       {"msg_id": "m1"}))
    kind, payload = p.ws.sent[0]
    assert kind == "cache_cleanup_result"
    assert payload["dry_run"] is True
    assert payload["ok"] is True
    assert payload["device_id"] == p.device_id
    assert any(d["item_id"] == "a" for d in payload["deleted"])
    assert path.exists(), "dry-run must not delete"


def test_commit_deletes_unreferenced_and_prunes_index(tmp_path):
    p = _player(tmp_path)
    a = _item("a")
    path = _cache_file(p, a)
    _run(p._on_message("cache_cleanup",
                       {"device_id": p.device_id, "request_id": "r1",
                        "mode": "unreferenced"},
                       {"msg_id": "m1"}))
    kind, payload = p.ws.sent[0]
    assert kind == "cache_cleanup_result"
    assert payload["ok"] is True
    assert payload["dry_run"] is False
    assert any(d["item_id"] == "a" for d in payload["deleted"])
    assert payload["freed_bytes"] == 1000
    assert not path.exists(), "commit must delete the reclaimable blob"
    assert "a" not in p.downloader._entries, "index pruned"


# --- protection via live player state -----------------------------------
def test_active_generation_and_playing_protected_leftover_reclaimed(tmp_path):
    """The whole active playlist (active generation) is protected; the playing
    item shows 'playing'; a leftover blob from an OLD playlist (no longer active,
    root-cause of the recent-3 pinning bug) is reclaimable."""
    p = _player(tmp_path)
    a, b, c = _item("a"), _item("b"), _item("c")
    pa, pb, pc = _cache_file(p, a), _cache_file(p, b), _cache_file(p, c)
    # active playlist is [a, b], playing a. c is a leftover from a past list.
    p.playlist = _playlist("PL", "push-1", [a, b])
    p.index = 0
    p.play_state = "playing"
    _run(p._on_message("cache_cleanup",
                       {"device_id": p.device_id, "request_id": "r1",
                        "mode": "unreferenced"},
                       {"msg_id": "m1"}))
    _, payload = p.ws.sent[0]
    assert pa.exists(), "playing item protected"
    assert pb.exists(), "active-generation item protected"
    assert not pc.exists(), "leftover item reclaimed"
    reasons = {s["item_id"]: s["reason"] for s in payload["skipped"]}
    assert reasons.get("a") == "playing"
    assert reasons.get("b") == "active"
    assert [d["item_id"] for d in payload["deleted"]] == ["c"]


def test_last_task_item_is_protected(tmp_path):
    p = _player(tmp_path)
    a = _item("a")
    pa = _cache_file(p, a)
    pl = _playlist("PL", "push-1", [a])
    p.state.store_playlist(pl)
    p.state.set_last_task({"playlist_id": "PL", "index": 0, "seek_ms": 0})
    _run(p._on_message("cache_cleanup",
                       {"device_id": p.device_id, "request_id": "r1",
                        "mode": "unreferenced"},
                       {"msg_id": "m1"}))
    _, payload = p.ws.sent[0]
    assert pa.exists(), "last_task item protected"
    assert {"item_id": "a", "reason": "last_task"} in payload["skipped"]


# --- generation fail-closed ---------------------------------------------
def test_expected_push_mismatch_deletes_nothing(tmp_path):
    p = _player(tmp_path)
    a = _item("a")
    pa = _cache_file(p, a)
    p.playlist = _playlist("PL", "push-current", [a], index=0)
    p.index = 0
    p.play_state = "idle"  # not playing → 'a' would otherwise be reclaimable
    _run(p._on_message("cache_cleanup",
                       {"device_id": p.device_id, "request_id": "r1",
                        "mode": "selected", "item_ids": ["a"],
                        "expected_push_id": "push-STALE"},
                       {"msg_id": "m1"}))
    _, payload = p.ws.sent[0]
    assert payload["ok"] is False
    assert payload["error"] == "generation_mismatch"
    assert pa.exists()


# --- inventory ----------------------------------------------------------
def test_cache_inventory_returns_states_and_reasons(tmp_path):
    p = _player(tmp_path)
    a, b = _item("a"), _item("b")
    _cache_file(p, a)
    _cache_file(p, b)
    p.playlist = _playlist("PL", "push-1", [a])  # a active/playing; b leftover
    p.index = 0
    p.play_state = "playing"
    _run(p._on_message("cache_inventory",
                       {"device_id": p.device_id, "request_id": "inv-1"},
                       {"msg_id": "m1"}))
    kind, payload = p.ws.sent[0]
    assert kind == "cache_inventory_result"
    assert payload["request_id"] == "inv-1"
    assert payload["device_id"] == p.device_id
    by_id = {it["item_id"]: it for it in payload["items"]}
    assert by_id["a"]["protection_reasons"] == ["playing"]
    assert by_id["b"]["protection_reasons"] == []
    assert by_id["a"]["bytes"] == 1000
    assert "content_key" in by_id["a"]


# --- status summary -----------------------------------------------------
def test_live_cache_summary_shape(tmp_path):
    p = _player(tmp_path)
    a, b = _item("a"), _item("b")
    _cache_file(p, a)
    _cache_file(p, b)
    p.playlist = _playlist("PL", "push-1", [a])  # a active; b leftover
    p.index = 0
    p.play_state = "playing"
    summ = p._cache_summary()
    assert summ["ready_items"] == 2
    assert summ["total_bytes"] == 2000
    assert summ["protected_items"] == 1  # a (playing/active)
    assert summ["reclaimable_items"] == 1  # b
    assert summ["reclaimable_bytes"] == 1000


def test_status_includes_cache_summary(tmp_path):
    p = _player(tmp_path)
    a = _item("a")
    _cache_file(p, a)
    _run(p._send_status())
    kinds = {k: v for k, v in p.ws.sent}
    assert "cache_summary" in kinds["status"]
    assert kinds["status"]["cache_summary"]["ready_items"] == 1
