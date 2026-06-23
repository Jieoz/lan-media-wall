"""Routing / fan-out by the envelope `to` field (§2, §9.3).

`to` forms supported:
  - "broker"            -> handled locally, no fan-out target
  - "player:<id>"       -> a single player connection
  - "group:<id>"        -> all online players in that group
  - "all"               -> all online players
  - "controller:<id>"   -> a single controller connection
A target may be offline/absent; resolution simply yields whatever is present.
"""
from __future__ import annotations

from typing import Iterable, List


def parse_addr(addr: str):
    """Split an address into (kind, ident). kind in
    {broker, player, group, controller, all}."""
    if addr == "broker":
        return ("broker", None)
    if addr == "all":
        return ("all", None)
    if ":" in addr:
        kind, _, ident = addr.partition(":")
        if kind in ("player", "group", "controller"):
            return (kind, ident)
    return ("unknown", addr)


def resolve_player_targets(to: str, registry, players: dict) -> List:
    """Return the list of live player connections matching `to`.

    `players` maps device_id -> connection object.
    `registry` supplies group membership.
    """
    kind, ident = parse_addr(to)
    out: List = []
    if kind == "all":
        out = list(players.values())
    elif kind == "player":
        conn = players.get(ident)
        if conn is not None:
            out = [conn]
    elif kind == "group":
        for device_id in registry.members(ident, online_only=True):
            conn = players.get(device_id)
            if conn is not None:
                out.append(conn)
    return out


def dedup_conns(conns: Iterable) -> List:
    """Preserve order, drop duplicate connection objects."""
    seen = set()
    out = []
    for c in conns:
        key = id(c)
        if key not in seen:
            seen.add(key)
            out.append(c)
    return out
