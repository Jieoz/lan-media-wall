"""CacheCleanup — proven-safe cache cleanup core (design §3.2 / §4.2).

One planner drives BOTH dry-run and commit. The player is the sole deletion
authority: requests carry item ids (never paths); identity is resolved to a
physical ``content_key`` locally; a blob is deleted only when NO protected item
references it (see :mod:`cache_refs`).

Safety invariants:
  * **fail-closed generation guard** — ``expected_push_id`` is checked before
    planning and RE-checked immediately before the first physical delete, under
    the cleanup lock. A mismatch/late change deletes NOTHING
    (``generation_mismatch`` / ``generation_changed``).
  * **idempotency** — a committed (destructive) ``request_id`` is journaled with
    its terminal result; a repeat returns that exact result and never deletes
    twice. Dry-runs are non-destructive and not journaled.
  * **structured result** — per-item ``deleted`` / ``skipped`` / ``failed`` with
    distinct reasons, ``freed_bytes`` (counted once per physical blob), and a
    ``summary_after``. No optimistic generic ACK.

The backend is duck-typed (``CacheBackend`` below) so this stays unit-testable
and so Android's ``CacheCleanup.kt`` can mirror the exact algorithm.
"""
from __future__ import annotations

import threading
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import cache_refs as R

# top-level operation errors (whole-op aborts)
GENERATION_MISMATCH = "generation_mismatch"
GENERATION_CHANGED = "generation_changed"
# per-item failure reason
DELETE_FAILED = "delete_failed"

_JOURNAL_MAX = 128  # bounded idempotency journal (design req. 7)


@dataclass
class CleanupRequest:
    request_id: str
    mode: str = "unreferenced"          # "unreferenced" | "selected"
    item_ids: Optional[List[str]] = None  # selected mode only; item ids, no paths
    dry_run: bool = False
    expected_push_id: Optional[str] = None
    reason: str = "manual"              # manual | after_playlist_replace | quota


@dataclass
class _Plan:
    """Planner output — identical for dry-run and commit."""
    # content_key -> {"item_ids": [...], "bytes": int}
    delete_by_key: "OrderedDict[str, Dict[str, Any]]" = field(
        default_factory=OrderedDict)
    skipped: List[Dict[str, str]] = field(default_factory=list)


class CacheCleanup:
    """Owns the cleanup transaction + a bounded per-request journal."""

    def __init__(self, backend: Any, *, lock: Optional[threading.RLock] = None):
        self._be = backend
        self._lock = lock or threading.RLock()
        self._journal: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()

    # --- public entrypoint -------------------------------------------
    def run(self, request: CleanupRequest) -> Dict[str, Any]:
        with self._lock:
            # idempotency: a committed request_id replays its terminal result.
            prior = self._journal.get(request.request_id)
            if prior is not None:
                replay = dict(prior)
                replay["idempotent_replay"] = True
                return replay

            observed_push = self._be.current_push_id()

            # fail-closed generation guard (pre-plan)
            if request.expected_push_id is not None and \
                    request.expected_push_id != observed_push:
                return self._abort(request, GENERATION_MISMATCH, observed_push)

            snapshot = self._be.build_snapshot()
            plan = self._plan(request, snapshot)

            if request.dry_run:
                # report candidates; mutate neither disk nor index.
                return self._render(request, plan, observed_push,
                                    deleted=self._planned_as_deleted(plan),
                                    failed=[], dry_run=True, committed=False)

            # RE-validate generation under the lock, just before deleting. If the
            # adopted generation moved since we read it, abort deleting nothing.
            recheck = self._be.current_push_id()
            if recheck != observed_push or (
                    request.expected_push_id is not None
                    and request.expected_push_id != recheck):
                return self._abort(request, GENERATION_CHANGED, recheck)

            deleted, failed = self._commit(plan)
            result = self._render(request, plan, recheck, deleted=deleted,
                                  failed=failed, dry_run=False, committed=True)
            self._journal_put(request.request_id, result)
            return result

    # --- planning (shared by dry-run + commit) -----------------------
    def _plan(self, request: CleanupRequest,
              snapshot: R.CacheReferenceSnapshot) -> _Plan:
        plan = _Plan()
        if request.mode == "selected":
            candidate_ids = list(request.item_ids or [])
        else:
            candidate_ids = [it["item_id"] for it in self._be.inventory()
                             if it.get("item_id") is not None]

        for iid in candidate_ids:
            kind, reason = snapshot.classify_item(iid)
            if kind is not None or reason is not None:
                # protected (direct/shared) or not_found → skipped, distinct reason
                plan.skipped.append({"item_id": iid, "reason": reason})
                continue
            key = snapshot.content_key_for(iid)
            size = self._be.size_of(key) if key is not None else None
            if key is None or size is None:
                # known item id but the physical file is already gone
                plan.skipped.append({"item_id": iid, "reason": R.NOT_FOUND})
                continue
            entry = plan.delete_by_key.get(key)
            if entry is None:
                entry = {"item_ids": [], "bytes": int(size)}
                plan.delete_by_key[key] = entry
            entry["item_ids"].append(iid)
        return plan

    # --- commit ------------------------------------------------------
    def _commit(self, plan: _Plan):
        deleted: List[Dict[str, Any]] = []
        failed: List[Dict[str, str]] = []
        for key, entry in plan.delete_by_key.items():
            ok = self._be.delete(key)
            if not ok:
                for iid in entry["item_ids"]:
                    failed.append({"item_id": iid, "reason": DELETE_FAILED})
                continue
            # prune in-memory/persistent index for every id sharing this blob
            self._be.prune_index(entry["item_ids"])
            for i, iid in enumerate(entry["item_ids"]):
                deleted.append({
                    "item_id": iid,
                    "content_key": key,
                    # freed bytes counted once per physical blob (first id only)
                    "bytes": entry["bytes"] if i == 0 else 0,
                })
        return deleted, failed

    # --- rendering ---------------------------------------------------
    def _planned_as_deleted(self, plan: _Plan) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        for key, entry in plan.delete_by_key.items():
            for i, iid in enumerate(entry["item_ids"]):
                out.append({"item_id": iid, "content_key": key,
                            "bytes": entry["bytes"] if i == 0 else 0})
        return out

    def _render(self, request: CleanupRequest, plan: _Plan,
                observed_push: Optional[str], *, deleted, failed,
                dry_run: bool, committed: bool) -> Dict[str, Any]:
        freed = sum(d["bytes"] for d in deleted)
        return {
            "request_id": request.request_id,
            "ok": True,
            "error": "",
            "dry_run": dry_run,
            "mode": request.mode,
            "reason": request.reason,
            "expected_push_id": request.expected_push_id,
            "observed_push_id": observed_push,
            "deleted": deleted,
            "skipped": list(plan.skipped),
            "failed": list(failed),
            "freed_bytes": freed,
            "summary_after": self._be.summary(),
        }

    def _abort(self, request: CleanupRequest, error: str,
               observed_push: Optional[str]) -> Dict[str, Any]:
        result = {
            "request_id": request.request_id,
            "ok": False,
            "error": error,
            "dry_run": request.dry_run,
            "mode": request.mode,
            "reason": request.reason,
            "expected_push_id": request.expected_push_id,
            "observed_push_id": observed_push,
            "deleted": [],
            "skipped": [],
            "failed": [],
            "freed_bytes": 0,
            "summary_after": self._be.summary(),
        }
        # a generation abort is terminal for this request_id (idempotent replay).
        self._journal_put(request.request_id, result)
        return result

    # --- bounded journal ---------------------------------------------
    def _journal_put(self, request_id: str, result: Dict[str, Any]) -> None:
        self._journal[request_id] = dict(result)
        self._journal.move_to_end(request_id)
        while len(self._journal) > _JOURNAL_MAX:
            self._journal.popitem(last=False)
