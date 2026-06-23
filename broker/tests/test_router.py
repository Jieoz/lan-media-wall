"""Router address parsing + target resolution (§2/§9.3)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import router  # noqa: E402


class FakeReg:
    def __init__(self, members):
        self._m = members

    def members(self, group_id, online_only=False):
        return self._m.get(group_id, [])


def test_parse_addr():
    assert router.parse_addr("broker") == ("broker", None)
    assert router.parse_addr("all") == ("all", None)
    assert router.parse_addr("player:win-01") == ("player", "win-01")
    assert router.parse_addr("group:lobby") == ("group", "lobby")
    assert router.parse_addr("controller:phone") == ("controller", "phone")
    assert router.parse_addr("garbage")[0] == "unknown"


def test_resolve_all():
    players = {"a": "CA", "b": "CB"}
    reg = FakeReg({})
    out = router.resolve_player_targets("all", reg, players)
    assert set(out) == {"CA", "CB"}


def test_resolve_single_player():
    players = {"a": "CA"}
    out = router.resolve_player_targets("player:a", FakeReg({}), players)
    assert out == ["CA"]
    # missing player resolves to empty
    assert router.resolve_player_targets("player:zzz", FakeReg({}), players) == []


def test_resolve_group():
    players = {"a": "CA", "b": "CB", "c": "CC"}
    reg = FakeReg({"lobby": ["a", "c"]})
    out = router.resolve_player_targets("group:lobby", reg, players)
    assert set(out) == {"CA", "CC"}


def test_dedup_conns():
    x, y = object(), object()
    assert router.dedup_conns([x, x, y, x]) == [x, y]
