"""Three-phase handshake state machine (§9) + registry persistence."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import sync as sync_mod  # noqa: E402
import registry as registry_mod  # noqa: E402


def test_session_collects_all_ready():
    mgr = sync_mod.SyncManager(buffer_ms=1500, timeout_ms=2000)
    mgr.start("s1", "lobby", "pl-1", {"a", "b"}, now_ms=10_000)
    assert mgr.on_ready("lobby", "a") is None      # not complete yet
    session = mgr.on_ready("lobby", "b")           # now complete
    assert session is not None
    assert session.all_ready()
    play_at = mgr.complete(session, now_ms=11_000)
    assert play_at == 11_000 + 1500


def test_ready_from_unknown_member_ignored():
    mgr = sync_mod.SyncManager()
    s = mgr.start("s1", "lobby", "pl-1", {"a", "b"}, now_ms=0)
    mgr.on_ready("lobby", "zzz")   # not in expected
    assert not s.all_ready()


def test_timeout_fires_for_ready_subset():
    mgr = sync_mod.SyncManager(buffer_ms=1500, timeout_ms=2000)
    s = mgr.start("s1", "lobby", "pl-1", {"a", "b", "c"}, now_ms=0)
    mgr.on_ready("lobby", "a")
    # before deadline: not expired
    assert mgr.expired_sessions(now_ms=1999) == []
    expired = mgr.expired_sessions(now_ms=2000)
    assert len(expired) == 1
    assert expired[0].ready_members() == ["a"]
    play_at = mgr.complete(expired[0], now_ms=2000)
    assert play_at == 2000 + 1500


def test_compute_play_at():
    assert sync_mod.compute_play_at(1000, 1500) == 2500


def test_sync_false_path_is_caller_side():
    # The manager itself only models sync=true; sanity: empty expected never
    # reports all_ready (broker.py handles sync=false directly).
    mgr = sync_mod.SyncManager()
    s = mgr.start("s1", "g", "pl", set(), now_ms=0)
    assert not s.all_ready()


def test_registry_persist_roundtrip():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "state.json")
        reg = registry_mod.Registry(path)
        reg.register("win-01", device_name="大厅左屏", group_id="lobby",
                     ip="192.168.1.50")
        reg.assign_group("win-01", "hall")
        # reload from disk
        reg2 = registry_mod.Registry(path)
        dev = reg2.get("win-01")
        assert dev is not None
        assert dev.device_name == "大厅左屏"
        assert dev.group_id == "hall"      # assignment persisted
        assert dev.last_ip == "192.168.1.50"
        # online state is volatile, not persisted
        assert dev.online is False


def test_registry_group_membership():
    with tempfile.TemporaryDirectory() as d:
        reg = registry_mod.Registry(os.path.join(d, "s.json"))
        reg.register("a", group_id="g1")
        reg.register("b", group_id="g1")
        reg.register("c", group_id="g2")
        assert set(reg.members("g1")) == {"a", "b"}
        # online_only filters on the volatile flag
        reg.set_offline("a")
        assert reg.members("g1", online_only=True) == ["b"]


def test_groups_snapshot_shape():
    with tempfile.TemporaryDirectory() as d:
        reg = registry_mod.Registry(os.path.join(d, "s.json"))
        reg.register("a", group_id="lobby")
        reg.set_group_meta("lobby", name="大厅", sync=True,
                           playlist_id="pl-1")
        snap = reg.groups_snapshot()
        lobby = next(g for g in snap if g["group_id"] == "lobby")
        assert lobby["name"] == "大厅"
        assert lobby["sync"] is True
        assert lobby["members"] == ["a"]
