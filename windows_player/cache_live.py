"""LiveCacheBackend — binds the proven-safe cleanup core to the REAL player.

This is the Phase B adapter (design §4.1/§4.2, protocol §27): it implements the
duck-typed ``CacheBackend`` that :class:`cache_cleanup.CacheCleanup` and
:class:`cache_refs.CacheReferenceSnapshot` consume, reading live state from the
running :class:`main.Player` (active playlist, currently-playing item, prepared
item, ``last_task`` resume, in-flight downloads) and the on-disk
:class:`downloader.Downloader` cache map.

Deletion authority stays with the player: the controller only ever names item
ids; identity is resolved to a physical ``content_key`` here (sha256 when known,
else the normalized on-disk target path). A blob is deleted only when NO
protected item references it — shared-content protection is transitive.

Historical playlist metadata does NOT hard-pin media (root-cause fix): only the
active generation, the playing source, a prepared-not-switched item, a valid
``last_task``, in-flight ``.part`` downloads, and explicit pins protect a blob.
"""
from __future__ import annotations

import os
from typing import Any, Dict, List, Optional

import cache_refs as R


def content_key_of(item: Dict[str, Any]) -> Optional[str]:
    """Physical content identity: sha256 when known (so identical media dedupes),
    else a normalized absolute target-path key. Never a raw controller path."""
    if item is None:
        return None
    sha = item.get("sha256")
    if sha:
        return f"sha256:{str(sha).lower()}"
    path = item.get("_local_path")
    if path:
        return f"path:{os.path.normcase(os.path.abspath(str(path)))}"
    iid = item.get("item_id")
    return f"id:{iid}" if iid is not None else None


class LiveCacheBackend:
    """Adapts a live ``Player`` + ``Downloader`` to the CacheBackend protocol.

    Reads player state lazily at each call so a single long-lived backend always
    plans against the CURRENT generation (the fail-closed guard depends on it).
    """

    def __init__(self, player: Any):
        self._p = player
        # content_key -> physical Path, populated by build_snapshot() and reused
        # by size_of()/delete() within the same run.
        self._key_to_path: Dict[str, str] = {}
        # content_key -> item_id, so delete() can prune the downloader index.
        self._key_to_item: Dict[str, str] = {}

    # --- CacheBackend protocol ---------------------------------------
    def content_key_of(self, item: Dict[str, Any]) -> Optional[str]:
        return content_key_of(item)

    def current_push_id(self) -> Optional[str]:
        pl = self._p.playlist
        return pl.get("push_id") if pl else None

    def inventory(self) -> List[Dict[str, Any]]:
        """Everything physically on disk (ready), enriched with playlist metadata
        (sha/name) when we know it, so content keys dedupe correctly. Playlist
        history does NOT enter protection — it only supplies identity here."""
        meta = self._item_meta_index()
        out: List[Dict[str, Any]] = []
        for item_id, path in self._p.downloader.ready_paths().items():
            base = dict(meta.get(item_id) or {"item_id": item_id})
            base["item_id"] = item_id
            base["_local_path"] = str(path)
            out.append(base)
        return out

    def build_snapshot(self) -> R.CacheReferenceSnapshot:
        p = self._p
        inv = self.inventory()

        # Reset the resolution maps for this run and record every id<->key<->path
        # relationship the snapshot will know about.
        self._key_to_path = {}
        self._key_to_item = {}

        def note(item: Dict[str, Any]) -> None:
            key = content_key_of(item)
            if key is None:
                return
            lp = item.get("_local_path")
            if lp:
                self._key_to_path.setdefault(key, str(lp))
            iid = item.get("item_id")
            if iid is not None:
                self._key_to_item.setdefault(key, iid)

        active = self._active_items()
        playing = self._playing_item()
        prepared = self._prepared_items()
        resume = self._resume_items()
        inflight = self._inflight_items()

        for group in (inv, active, prepared, resume, inflight):
            for it in group:
                note(it)
        if playing is not None:
            note(playing)

        return R.CacheReferenceSnapshot.build(
            content_key_of=content_key_of,
            inventory=inv,
            active_items=active,
            prepared_items=prepared,
            playing_item=playing,
            resume_items=resume,
            inflight_items=inflight,
            pinned_items=[],
        )

    def size_of(self, content_key: str) -> Optional[int]:
        path = self._key_to_path.get(content_key)
        if not path:
            return None
        try:
            return os.path.getsize(path)
        except OSError:
            return None

    def delete(self, content_key: str) -> bool:
        """Physically delete the blob (+ any .part sibling). True on success."""
        path = self._key_to_path.get(content_key)
        if not path:
            return False
        try:
            if os.path.exists(path):
                os.remove(path)
            part = path + ".part"
            if os.path.exists(part):
                os.remove(part)
            return True
        except OSError:
            return False

    def prune_index(self, item_ids: List[str]) -> None:
        self._p.downloader.prune_entries(item_ids)

    def summary(self) -> Dict[str, Any]:
        return self._p._cache_summary()

    # --- live-state extraction ---------------------------------------
    def _item_meta_index(self) -> Dict[str, Dict[str, Any]]:
        """item_id -> item dict, gathered from every playlist the player knows
        (active + persisted history + last_task target). Identity source ONLY;
        presence here never protects a blob."""
        idx: Dict[str, Dict[str, Any]] = {}
        pls: List[Dict[str, Any]] = []
        if self._p.playlist:
            pls.append(self._p.playlist)
        try:
            pls.extend(self._p.state.playlists.values())
        except Exception:
            pass
        for pl in pls:
            for it in pl.get("items", []) or []:
                iid = it.get("item_id")
                if iid is not None and iid not in idx:
                    idx[iid] = it
        return idx

    def _active_items(self) -> List[Dict[str, Any]]:
        pl = self._p.playlist
        return list(pl.get("items", []) or []) if pl else []

    def _playing_item(self) -> Optional[Dict[str, Any]]:
        if self._p.play_state in ("playing", "paused"):
            return self._p._current_item()
        return None

    def _prepared_items(self) -> List[Dict[str, Any]]:
        # A buffering (prepared-not-switched) item is the current index target.
        if self._p.play_state == "buffering":
            it = self._p._current_item()
            return [it] if it is not None else []
        return []

    def _resume_items(self) -> List[Dict[str, Any]]:
        task = self._p.state.last_task
        if not task:
            return []
        pl = self._p._resolve_playlist(task.get("playlist_id"))
        if pl is None:
            return []
        items = pl.get("items", []) or []
        idx = int(task.get("index", 0))
        if 0 <= idx < len(items):
            return [items[idx]]
        return []

    def _inflight_items(self) -> List[Dict[str, Any]]:
        meta = self._item_meta_index()
        out: List[Dict[str, Any]] = []
        for item_id, path in self._p.downloader.inflight_paths().items():
            base = dict(meta.get(item_id) or {"item_id": item_id})
            base["item_id"] = item_id
            if path:
                base["_local_path"] = str(path)
            out.append(base)
        return out
