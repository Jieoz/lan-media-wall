"""CacheReferenceSnapshot — player-local protection union (design §4.1).

Pure model. Given the live player state (active/prepared/playing/resume/inflight/
pinned item sets) plus the on-disk inventory, it derives, per *content blob*:

  - the set of item ids that resolve to that blob (``content_key`` = sha256 when
    known, else a normalized target path — supplied by ``content_key_of``);
  - whether the blob is protected, and by which reason.

Protection is a UNION keyed by content: a blob is protected while ANY item that
references it holds a protecting reason. This is what makes shared media safe —
deleting by content_key means one live reference protects every id that shares
the physical file.

Deliberately excluded from the protection union: mere presence in historical
playlist metadata. Playlist history may be retained for audit/resume, but it does
NOT hard-pin media (root-cause fix for the "recent-3 lists pin everything" bug).

Reason precedence when an item has several direct reasons: PLAYING > ACTIVE >
PREPARED > INFLIGHT > LAST_TASK > PINNED (most operationally urgent first).
"""
from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional, Set, Tuple

# --- protection / skip reason constants (wire-facing, design §3.2) --------
PLAYING = "playing"
ACTIVE = "active"
PREPARED = "prepared"
INFLIGHT = "inflight"
LAST_TASK = "last_task"
PINNED = "pinned"
SHARED_CONTENT = "shared_content"
NOT_FOUND = "not_found"

# Direct-reason precedence, most urgent first.
_PRECEDENCE = (PLAYING, ACTIVE, PREPARED, INFLIGHT, LAST_TASK, PINNED)

Item = Dict[str, Any]


class CacheReferenceSnapshot:
    """Immutable snapshot of what protects what. Build via :meth:`build`."""

    def __init__(self,
                 item_to_key: Dict[str, str],
                 key_to_items: Dict[str, Set[str]],
                 direct_reasons: Dict[str, str]):
        # item_id -> content_key
        self._item_to_key = item_to_key
        # content_key -> {item_id, ...}
        self._key_to_items = key_to_items
        # item_id -> single strongest direct protecting reason (subset of items)
        self._direct = direct_reasons

    # --- construction -------------------------------------------------
    @classmethod
    def build(cls, *,
              content_key_of: Callable[[Item], Optional[str]],
              inventory: List[Item],
              active_items: Optional[List[Item]] = None,
              prepared_items: Optional[List[Item]] = None,
              playing_item: Optional[Item] = None,
              resume_items: Optional[List[Item]] = None,
              inflight_items: Optional[List[Item]] = None,
              pinned_items: Optional[List[Item]] = None,
              ) -> "CacheReferenceSnapshot":
        item_to_key: Dict[str, str] = {}
        key_to_items: Dict[str, Set[str]] = {}

        def register(it: Item) -> None:
            iid = it.get("item_id")
            if iid is None:
                return
            key = content_key_of(it)
            if key is None:
                return
            item_to_key[iid] = key
            key_to_items.setdefault(key, set()).add(iid)

        # Everything the player knows about contributes to the id<->blob maps,
        # so shared-content protection can reach ids that live only in inventory.
        for group in (inventory, active_items, prepared_items, resume_items,
                      inflight_items, pinned_items):
            for it in group or []:
                register(it)
        if playing_item is not None:
            register(playing_item)

        # Assign the strongest direct reason per item id. Iterate weakest→
        # strongest so stronger reasons overwrite; PLAYING wins last.
        direct: Dict[str, str] = {}

        def mark(items: Optional[List[Item]], reason: str) -> None:
            for it in items or []:
                iid = it.get("item_id")
                if iid is not None:
                    direct[iid] = reason

        # apply in reverse precedence (weakest first)
        mark(pinned_items, PINNED)
        mark(resume_items, LAST_TASK)
        mark(inflight_items, INFLIGHT)
        mark(prepared_items, PREPARED)
        mark(active_items, ACTIVE)
        if playing_item is not None and playing_item.get("item_id") is not None:
            direct[playing_item["item_id"]] = PLAYING

        return cls(item_to_key, key_to_items, direct)

    # --- queries ------------------------------------------------------
    def content_key_for(self, item_id: str) -> Optional[str]:
        return self._item_to_key.get(item_id)

    def items_for_key(self, content_key: str) -> Set[str]:
        return set(self._key_to_items.get(content_key, set()))

    def direct_reason(self, item_id: str) -> Optional[str]:
        """The strongest reason this exact item id is protected, or None."""
        return self._direct.get(item_id)

    def is_protected(self, content_key: Optional[str]) -> bool:
        """True iff ANY item referencing this blob holds a direct reason."""
        if content_key is None:
            return False
        for iid in self._key_to_items.get(content_key, set()):
            if iid in self._direct:
                return True
        return False

    def protecting_reason(self, content_key: str) -> Optional[str]:
        """The strongest direct reason protecting this blob (across all ids)."""
        best: Optional[str] = None
        best_rank = len(_PRECEDENCE)
        for iid in self._key_to_items.get(content_key, set()):
            r = self._direct.get(iid)
            if r is not None and _PRECEDENCE.index(r) < best_rank:
                best, best_rank = r, _PRECEDENCE.index(r)
        return best

    def classify_item(self, item_id: str) -> Tuple[Optional[str], Optional[str]]:
        """Classify a deletion candidate.

        Returns ``(kind, reason)``:
          - ``("direct", reason)``  — this exact item is itself protected;
          - ``("shared", "shared_content")`` — deletable-looking, but its blob is
            protected by ANOTHER item id (do not physically delete);
          - ``(None, "not_found")`` — unknown item id;
          - ``(None, None)``        — reclaimable.
        """
        key = self._item_to_key.get(item_id)
        if key is None:
            return (None, NOT_FOUND)
        direct = self._direct.get(item_id)
        if direct is not None:
            return ("direct", direct)
        # not directly protected — is the shared blob protected by someone else?
        if self.is_protected(key):
            return ("shared", SHARED_CONTENT)
        return (None, None)
