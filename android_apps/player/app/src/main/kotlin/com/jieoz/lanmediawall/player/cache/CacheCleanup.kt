package com.jieoz.lanmediawall.player.cache

import java.security.MessageDigest

/**
 * CacheCleanup — proven-safe cache cleanup core (design §3.2 / §4.2).
 *
 * Behavioural mirror of the Windows player's `cache_cleanup.py`. One planner
 * drives BOTH dry-run and commit. The player is the sole deletion authority:
 * requests carry item ids (never paths); identity is resolved to a physical
 * content key locally; a blob is deleted only when NO protected item references
 * it (see [CacheReferenceSnapshot]).
 *
 * Safety invariants:
 *  - fail-closed generation guard: `expectedPushId` is checked before planning
 *    and RE-checked immediately before the first physical delete, under the
 *    cleanup lock. A mismatch/late change deletes NOTHING.
 *  - idempotency: a committed (destructive) `requestId` is journaled with its
 *    terminal result; a repeat returns that result and never deletes twice.
 *    Dry-runs are non-destructive and not journaled.
 *  - structured result: per-item deleted/skipped/failed with distinct reasons,
 *    freedBytes (counted once per physical blob), and summaryAfter.
 *
 * [Backend] is an interface so this stays unit-testable and matches the Python
 * duck-typed backend contract. API-19 safe: no removeIf / stream / modern FS.
 */
class CacheCleanup(
    private val backend: Backend,
    // generation lock: SHARED with the player's playlist handlers. Held ONLY for
    // the fast generation validation + delete hand-off, NEVER for the O(N)
    // scan/plan — so the receive loop and playback transitions are not stalled
    // for a whole cleanup (design req. 10).
    private val genLock: Any = Any(),
) {
    // transaction lock: PRIVATE. Serializes cleanup runs against each other and
    // guards the idempotency journal, without blocking playlist handlers on the
    // generation lock for the scan duration.
    private val txnLock = Any()

    // bounded idempotency journal (design req. 7), insertion-ordered.
    private val journal = object : LinkedHashMap<String, CleanupResult>(
        16, 0.75f, false) {
        override fun removeEldestEntry(
            eldest: MutableMap.MutableEntry<String, CleanupResult>?
        ): Boolean = size > JOURNAL_MAX
    }

    // --- backend contract -------------------------------------------
    interface Backend {
        fun contentKeyOf(item: MediaItem): String?
        fun buildSnapshot(): CacheReferenceSnapshot
        fun inventory(): List<MediaItem>
        /** Physical size of the blob, or null when the file is already gone. */
        fun sizeOf(contentKey: String): Long?
        fun currentPushId(): String?
        /** Physically delete + return true on success (false = delete_failed). */
        fun delete(contentKey: String): Boolean
        /** Prune in-memory/persistent index for these ids. */
        fun pruneIndex(itemIds: List<String>)
        fun summary(): Map<String, Any?>
    }

    // --- request / result models ------------------------------------
    data class Request(
        val requestId: String,
        val mode: String = "unreferenced",     // "unreferenced" | "selected"
        val itemIds: List<String>? = null,      // selected mode; ids, never paths
        val dryRun: Boolean = false,
        val expectedPushId: String? = null,
        val reason: String = "manual",
        val target: String = "all",
    )

    data class Deleted(val itemId: String, val contentKey: String, val bytes: Long)
    data class Skipped(val itemId: String, val reason: String?)
    data class Failed(val itemId: String, val reason: String)

    data class CleanupResult(
        val requestId: String,
        val operationFingerprint: String,
        val ok: Boolean,
        val error: String,
        val dryRun: Boolean,
        val mode: String,
        val reason: String,
        val expectedPushId: String?,
        val observedPushId: String?,
        val deleted: List<Deleted>,
        val skipped: List<Skipped>,
        val failed: List<Failed>,
        val freedBytes: Long,
        val summaryAfter: Map<String, Any?>,
        val idempotentReplay: Boolean = false,
    )

    private class Plan {
        // contentKey -> ordered REQUESTED candidate ids that resolved to it.
        // Drives the honest `deleted` response (protocol reports what was asked).
        val deleteByKey = LinkedHashMap<String, MutableList<String>>()
        // contentKey -> EVERY alias id that resolves to it. When the one physical
        // file is deleted, all of these become invalid and must be pruned, or the
        // index keeps rows pointing at a deleted file (dangling-alias bug).
        val pruneByKey = LinkedHashMap<String, List<String>>()
        val keyBytes = LinkedHashMap<String, Long>()
        val skipped = ArrayList<Skipped>()
    }

    // --- public entrypoint ------------------------------------------
    fun run(request: Request): CleanupResult {
        // Serialize cleanups + protect the journal WITHOUT holding the shared
        // generation lock across the scan. The generation lock is taken only in
        // the tight critical sections (observeGeneration / commitLocked).
        synchronized(txnLock) {
            if (request.requestId.isBlank() ||
                request.mode !in setOf("selected", "unreferenced")) {
                return abort(request, INVALID_REQUEST, observeGeneration())
            }
            if (!request.dryRun && (request.mode != "selected" ||
                request.itemIds.isNullOrEmpty() || request.itemIds.any { it.isEmpty() } ||
                request.expectedPushId.isNullOrEmpty())) {
                return abort(request, INVALID_REQUEST, observeGeneration())
            }
            journal[request.requestId]?.let { return it.copy(idempotentReplay = true) }

            val observed = observeGeneration()

            // fail-closed generation guard (pre-plan)
            if (request.expectedPushId != null && request.expectedPushId != observed) {
                return abort(request, GENERATION_MISMATCH, observed)
            }

            // SCAN/PLAN OUTSIDE the generation lock — the long part. A generation
            // move that races the scan is caught fail-closed by the re-check in
            // commitLocked() before any physical delete.
            val snapshot = backend.buildSnapshot()
            val plan = plan(request, snapshot)

            if (request.dryRun) {
                return render(request, plan, observed,
                    deleted = plannedAsDeleted(plan), failed = emptyList(),
                    dryRun = true)
            }

            return commitLocked(request, plan, observed)
        }
    }

    private fun observeGeneration(): String? =
        synchronized(genLock) { backend.currentPushId() }

    /**
     * Generation-critical section: RE-validate the adopted generation and
     * perform every physical delete while holding the generation lock, so no
     * playlist swap can slip a newly-protected blob under us mid-batch. If the
     * generation moved since the pre-plan read, abort deleting NOTHING
     * (fail-closed). Held only for the fast re-check + deletes, not the scan.
     */
    private fun commitLocked(request: Request, plan: Plan,
                             observed: String?): CleanupResult {
        synchronized(genLock) {
            val recheck = backend.currentPushId()
            if (recheck != observed ||
                (request.expectedPushId != null && request.expectedPushId != recheck)) {
                return abort(request, GENERATION_CHANGED, recheck)
            }

            val (deleted, failed) = commit(plan)
            val result = render(request, plan, recheck, deleted = deleted,
                failed = failed, dryRun = false)
            journal[request.requestId] = result
            return result
        }
    }

    // --- planning (shared by dry-run + commit) ----------------------
    private fun plan(request: Request, snapshot: CacheReferenceSnapshot): Plan {
        val plan = Plan()
        val candidateIds: List<String> = if (request.mode == "selected") {
            // de-dupe requested ids: a repeated id must not report/prune twice.
            (request.itemIds ?: emptyList()).distinct()
        } else {
            backend.inventory().map { it.itemId }
        }
        for (iid in candidateIds) {
            val c = snapshot.classifyItem(iid)
            if (c.kind != CacheReferenceSnapshot.Kind.NONE || c.reason != null) {
                plan.skipped.add(Skipped(iid, c.reason))
                continue
            }
            val key = snapshot.contentKeyFor(iid)
            val size = if (key != null) backend.sizeOf(key) else null
            if (key == null || size == null) {
                plan.skipped.add(Skipped(iid, CacheReferenceSnapshot.NOT_FOUND))
                continue
            }
            val ids = plan.deleteByKey.getOrPut(key) {
                plan.keyBytes[key] = size
                // The blob reached here only because it is unprotected, so EVERY
                // alias sharing it is safe to prune once the file is deleted.
                plan.pruneByKey[key] = snapshot.itemsForKey(key).sorted()
                ArrayList()
            }
            ids.add(iid)
        }
        return plan
    }

    // --- commit ------------------------------------------------------
    private fun commit(plan: Plan): Pair<List<Deleted>, List<Failed>> {
        val deleted = ArrayList<Deleted>()
        val failed = ArrayList<Failed>()
        for ((key, ids) in plan.deleteByKey) {
            if (!backend.delete(key)) {
                for (iid in ids) failed.add(Failed(iid, DELETE_FAILED))
                continue
            }
            // The one physical blob is gone: prune EVERY alias resolving to it,
            // not just the requested candidates. Delete failure prunes nothing.
            backend.pruneIndex(plan.pruneByKey[key] ?: ids)
            val bytes = plan.keyBytes[key] ?: 0L
            ids.forEachIndexed { i, iid ->
                deleted.add(Deleted(iid, key, if (i == 0) bytes else 0L))
            }
        }
        return Pair(deleted, failed)
    }

    // --- rendering ---------------------------------------------------
    private fun plannedAsDeleted(plan: Plan): List<Deleted> {
        val out = ArrayList<Deleted>()
        for ((key, ids) in plan.deleteByKey) {
            val bytes = plan.keyBytes[key] ?: 0L
            ids.forEachIndexed { i, iid ->
                out.add(Deleted(iid, key, if (i == 0) bytes else 0L))
            }
        }
        return out
    }

    private fun render(request: Request, plan: Plan, observed: String?,
                       deleted: List<Deleted>, failed: List<Failed>,
                       dryRun: Boolean): CleanupResult {
        val freed = deleted.sumOf { it.bytes }
        return CleanupResult(
            requestId = request.requestId,
            operationFingerprint = operationFingerprint(request),
            ok = true, error = "",
            dryRun = dryRun, mode = request.mode, reason = request.reason,
            expectedPushId = request.expectedPushId, observedPushId = observed,
            deleted = deleted, skipped = ArrayList(plan.skipped), failed = failed,
            freedBytes = freed, summaryAfter = backend.summary(),
        )
    }

    private fun abort(request: Request, error: String,
                     observed: String?): CleanupResult {
        val result = CleanupResult(
            requestId = request.requestId,
            operationFingerprint = operationFingerprint(request),
            ok = false, error = error,
            dryRun = request.dryRun, mode = request.mode, reason = request.reason,
            expectedPushId = request.expectedPushId, observedPushId = observed,
            deleted = emptyList(), skipped = emptyList(), failed = emptyList(),
            freedBytes = 0L, summaryAfter = backend.summary(),
        )
        journal[request.requestId] = result  // terminal for this id
        return result
    }

    companion object {
        /**
         * Payload-derived fingerprint target, byte-identical to the broker
         * (`_cleanup_fingerprint`) and Windows (`_h_cache_cleanup`):
         * `device:<deviceId>` when the request is device-addressed, else
         * `group:<groupId>` when group-addressed, else `all`. Empty strings are
         * treated as absent (mirrors Python truthiness of the payload fields) so
         * a GROUP-addressed request produces a matching `group:` fingerprint the
         * broker's result gate accepts — never a spurious `device:` target.
         */
        fun targetFor(deviceId: String?, groupId: String?): String = when {
            !deviceId.isNullOrEmpty() -> "device:$deviceId"
            !groupId.isNullOrEmpty() -> "group:$groupId"
            else -> "all"
        }

        fun operationFingerprint(request: Request): String {
            val fields = ArrayList<String>()
            fields.add("cache_cleanup")
            fields.add(request.target)
            fields.add(request.mode)
            fields.add(if (request.dryRun) "true" else "false")
            fields.addAll(request.itemIds ?: emptyList())
            fields.add(request.expectedPushId ?: "")
            fields.add(request.reason)
            val canonical = fields.joinToString("") { value ->
                "${value.toByteArray(Charsets.UTF_8).size}:$value"
            }
            return MessageDigest.getInstance("SHA-256")
                .digest(canonical.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }

        const val GENERATION_MISMATCH = "generation_mismatch"
        const val GENERATION_CHANGED = "generation_changed"
        const val DELETE_FAILED = "delete_failed"
        const val INVALID_REQUEST = "invalid_request"
        private const val JOURNAL_MAX = 128
    }
}
