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

import hashlib
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
INVALID_REQUEST = "invalid_request"

_JOURNAL_MAX = 128  # bounded idempotency journal (design req. 7)


@dataclass
class CleanupRequest:
    request_id: str
    mode: str = "unreferenced"          # "unreferenced" | "selected"
    item_ids: Optional[List[str]] = None  # selected mode only; item ids, no paths
    dry_run: bool = False
    expected_push_id: Optional[str] = None
    reason: str = "manual"              # manual | after_playlist_replace | quota
    target: str = "all"


def operation_fingerprint(request_type: str, target: str, mode: str,
                          dry_run: bool, item_ids: Optional[List[str]],
                          expected_push_id: Optional[str], reason: str) -> str:
    """SHA-256 of a cross-platform, unambiguous length-prefixed field stream."""
    fields = [request_type, target, mode, "true" if dry_run else "false",
              *(item_ids or []), expected_push_id or "", reason]
    canonical = "".join(
        f"{len(str(value).encode('utf-8'))}:{value}" for value in fields)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


@dataclass
class _Plan:
    """Planner output — identical for dry-run and commit.

    Per physical ``content_key`` we track two distinct id sets:
      * ``item_ids`` — the requested candidate ids that resolved to this blob;
        these drive the honest ``deleted`` response (protocol reports what was
        asked for, per design §3.2).
      * ``prune_ids`` — EVERY inventory/index id that resolves to this blob.
        When the single physical file is deleted, all of these aliases become
        invalid and must be pruned, or the index keeps rows pointing at a
        deleted file (root-cause of the dangling-alias bug).
    """
    # content_key -> {"item_ids": [...], "bytes": int, "prune_ids": [...]}
    delete_by_key: "OrderedDict[str, Dict[str, Any]]" = field(
        default_factory=OrderedDict)
    skipped: List[Dict[str, str]] = field(default_factory=list)


class CacheCleanup:
    """Owns the cleanup transaction + a bounded per-request journal."""

    def __init__(self, backend: Any, *, lock: Optional[threading.RLock] = None):
        self._be = backend
        # generation lock: SHARED with the player's playlist handlers. Held ONLY
        # for the fast generation validation + delete hand-off, NEVER for the
        # O(N) scan/plan — so the receive loop and playback transitions are not
        # stalled for a whole cleanup (design req. 10).
        self._gen_lock = lock or threading.RLock()
        # transaction lock: PRIVATE. Serializes cleanup runs against each other
        # and guards the idempotency journal, without blocking playlist handlers.
        self._txn_lock = threading.RLock()
        self._journal: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()

    # --- public entrypoint -------------------------------------------
    def run(self, request: CleanupRequest) -> Dict[str, Any]:
        # Serialize cleanups + protect the journal WITHOUT holding the shared
        # generation lock across the scan. The generation lock is taken only in
        # the tight critical sections below (_observe_generation / _commit_locked).
        with self._txn_lock:
            if not request.request_id or request.mode not in ("selected", "unreferenced"):
                return self._abort(request, INVALID_REQUEST,
                                   self._observe_generation())
            if not request.dry_run and (
                    request.mode != "selected" or
                    not isinstance(request.item_ids, list) or
                    not request.item_ids or
                    not all(isinstance(i, str) and i for i in request.item_ids) or
                    not isinstance(request.expected_push_id, str) or
                    not request.expected_push_id):
                return self._abort(request, INVALID_REQUEST,
                                   self._observe_generation())
            # idempotency: a committed request_id replays its terminal result.
            prior = self._journal.get(request.request_id)
            if prior is not None:
                replay = dict(prior)
                replay["idempotent_replay"] = True
                return replay

            observed_push = self._observe_generation()

            # fail-closed generation guard (pre-plan)
            if request.expected_push_id is not None and \
                    request.expected_push_id != observed_push:
                return self._abort(request, GENERATION_MISMATCH, observed_push)

            # SCAN/PLAN OUTSIDE the generation lock — this is the long part. A
            # generation move that races the scan is caught fail-closed by the
            # re-check inside _commit_locked() before any physical delete.
            snapshot = self._be.build_snapshot()
            plan = self._plan(request, snapshot)

            if request.dry_run:
                # report candidates; mutate neither disk nor index.
                return self._render(request, plan, observed_push,
                                    deleted=self._planned_as_deleted(plan),
                                    failed=[], dry_run=True, committed=False)

            return self._commit_locked(request, plan, observed_push)

    def _observe_generation(self) -> Optional[str]:
        with self._gen_lock:
            return self._be.current_push_id()

    def _commit_locked(self, request: CleanupRequest, plan: _Plan,
                       observed_push: Optional[str]) -> Dict[str, Any]:
        """Generation-critical section: RE-validate the adopted generation and
        perform every physical delete while holding the generation lock, so no
        playlist swap can slip a newly-protected blob under us mid-batch. If the
        generation moved since the pre-plan read, abort deleting NOTHING
        (fail-closed). Held only for the fast re-check + deletes, not the scan."""
        with self._gen_lock:
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
            # de-dupe requested ids: a repeated id must not be reported twice
            # nor prune twice. Preserve first-seen order.
            candidate_ids = list(dict.fromkeys(request.item_ids or []))
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
                # The blob reached here only because it is unprotected, so EVERY
                # alias sharing it is safe to prune once the file is deleted.
                entry = {"item_ids": [], "bytes": int(size),
                         "prune_ids": sorted(snapshot.items_for_key(key))}
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
            # The one physical blob is gone: prune EVERY alias that resolves to
            # it (not just the requested candidates), so no index row is left
            # dangling at a deleted file. Delete failure prunes nothing.
            self._be.prune_index(entry["prune_ids"])
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
            "operation_fingerprint": operation_fingerprint(
                "cache_cleanup", request.target, request.mode, request.dry_run,
                request.item_ids, request.expected_push_id, request.reason),
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
            "operation_fingerprint": operation_fingerprint(
                "cache_cleanup", request.target, request.mode, request.dry_run,
                request.item_ids, request.expected_push_id, request.reason),
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
