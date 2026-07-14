"""Canonical semantic playlist hash — ``group_playlist_hash_v1`` (protocol §3.1).

Two playlists hash equal iff their *playback semantics* are equal. The canonical
input is a version-tagged, newline-delimited record built from ONLY:

  - ``loop_mode`` (the §6.3 fold: canonical ``loop_mode`` wins; else legacy
    ``loop`` → all/none), lowercased wire string;
  - ``sync`` (bool);
  - the ORDERED items, each contributing ``url``, ``sha256`` (lowercased; empty
    when absent — legacy/un-hashed media), ``duration_ms`` (int; empty when
    absent) and the per-item ``loop`` bool.

It deliberately EXCLUDES ``playlist_id`` and ``push_id``: the former is reusable,
the latter is a per-replace generation token. The controller uses this hash to
distinguish *same content / different generation* from *divergent* content.

The exact string form is a cross-language contract: the Kotlin implementation
(`cache/CacheHash.kt`) must build the byte-identical string so the sha256 hex
matches (see tests/test_cache_hash.py ↔ CacheHashTest.kt, same fixture, same
pinned hex). Keep the two in lockstep — any format change is a protocol change.

Design note on separators: media URLs in this system never contain newlines or
NUL, so a newline-record / ``=``-field text form is unambiguous and avoids
depending on any JSON library's key ordering or number formatting (a real
cross-language footgun). Field values are used verbatim otherwise.
"""
from __future__ import annotations

import hashlib
from typing import Any, Dict, List

from loop_mode import resolve_loop_mode

CANONICAL_VERSION = "lmw-playlist-hash-v1"


def _norm_bool(v: Any) -> str:
    return "true" if bool(v) else "false"


def _norm_sha(v: Any) -> str:
    """Lowercase hex sha; empty string when absent. Case-insensitive so two
    peers that disagree only on hex case still hash equal."""
    if v is None:
        return ""
    return str(v).strip().lower()


def _norm_duration(v: Any) -> str:
    """Integer milliseconds as decimal text; empty when absent/uncoercible."""
    if v is None:
        return ""
    try:
        return str(int(v))
    except (TypeError, ValueError):
        return ""


def _item_record(item: Dict[str, Any]) -> str:
    url = str(item.get("url", ""))
    sha = _norm_sha(item.get("sha256"))
    dur = _norm_duration(item.get("duration_ms"))
    loop = _norm_bool(item.get("loop", False))
    return f"item\turl={url}\tsha256={sha}\tdur={dur}\tloop={loop}"


def canonical_playlist_string(playlist: Dict[str, Any]) -> str:
    """Build the canonical, cross-language-stable string for ``playlist``."""
    pl = playlist or {}
    mode = resolve_loop_mode(pl).value
    sync = _norm_bool(pl.get("sync", True))
    items: List[Dict[str, Any]] = pl.get("items", []) or []
    lines = [
        CANONICAL_VERSION,
        f"loop_mode={mode}",
        f"sync={sync}",
        f"count={len(items)}",
    ]
    for it in items:
        lines.append(_item_record(it if isinstance(it, dict) else {}))
    # trailing newline terminates the last record deterministically
    return "\n".join(lines) + "\n"


def canonical_playlist_hash(playlist: Dict[str, Any]) -> str:
    """Lowercase sha256 hex of the canonical playlist string."""
    canon = canonical_playlist_string(playlist)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()
