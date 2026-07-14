"""§6.3a playlist composition — replace / append / clear (pure, testable).

Kept deliberately parallel to the Android ``cache/PlaylistOps.kt`` merge so the
two players fold identical wire payloads into the same ordered active playlist.

  - replace (default, byte-equivalent to legacy): whole-list replace, play from
    index 0. An empty ``items`` under replace is the CLEAR signal (handled by
    the caller: clears the active playlist + current state, enters idle/black,
    but never deletes cached media inventory).
  - append: merge ``new_items`` onto the tail of the current ordered list,
    de-duped by ``item_id`` (same id updates in place, unknown ids appended).
    Existing indices never shift, so the caller's ``current_index`` stays valid.
    An empty append is a harmless no-op.
"""
from typing import Any, Dict, List

REPLACE = "replace"
APPEND = "append"


def normalize_mode(wire: Any) -> str:
    """Fold the wire ``mode`` string; unknown/missing -> replace (§6.3)."""
    if isinstance(wire, str) and wire.strip().lower() == APPEND:
        return APPEND
    return REPLACE


def merge_append(current_items: List[Dict[str, Any]],
                 new_items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Append de-duped by ``item_id``; same id updates in place (no new row)."""
    merged: List[Dict[str, Any]] = list(current_items)
    index_by_id = {
        it.get("item_id"): i for i, it in enumerate(merged)
        if it.get("item_id") is not None
    }
    for it in new_items:
        iid = it.get("item_id")
        if iid is not None and iid in index_by_id:
            merged[index_by_id[iid]] = it
        else:
            if iid is not None:
                index_by_id[iid] = len(merged)
            merged.append(it)
    return merged
