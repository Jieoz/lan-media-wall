package com.jieoz.lanmediawall.player.cache

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Call
import android.util.Log
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.min
import kotlin.random.Random

/**
 * Pure Range-resume math (protocol_spec §6) — extracted so it is unit-testable
 * without any network. Mirrors windows_player/downloader.py exactly.
 */
object RangeMath {
    /** Header to resume from [existingBytes]; null when starting fresh. */
    fun rangeHeader(existingBytes: Long): String? =
        if (existingBytes <= 0) null else "bytes=$existingBytes-"

    /** Integer 0–100 progress. Unknown total → 0 until done is signalled. */
    fun percent(downloaded: Long, total: Long?): Int {
        if (total == null || total <= 0) return 0
        return (downloaded * 100 / total).toInt().coerceIn(0, 100)
    }

    /**
     * Resolve full object size from a (possibly partial) response.
     *  - 206 + Content-Range "bytes a-b/TOTAL" → TOTAL authoritative
     *  - 206 + only Content-Length L → existing + L
     *  - 200 (server ignored Range) → Content-Length is the whole object
     */
    fun expectedTotal(
        existingBytes: Long, status: Int,
        contentLength: Long?, contentRangeTotal: Long?,
    ): Long? {
        if (status == 206) {
            if (contentRangeTotal != null) return contentRangeTotal
            if (contentLength != null) return existingBytes + contentLength
            return null
        }
        return contentLength
    }

    /** Parse TOTAL out of a Content-Range header: 'bytes 0-99/12345'. */
    fun parseContentRangeTotal(value: String?): Long? {
        if (value.isNullOrEmpty()) return null
        return try {
            val tail = value.substringAfterLast('/').trim()
            if (tail == "*") null else tail.toLong()
        } catch (e: Exception) {
            null
        }
    }
}

/** One cached item's state, rendered to the §5.1 status.cache string form. */
class CacheEntry(val itemId: String) {
    @Volatile var state: String = "pending" // pending|downloading|verifying|ready|error
    @Volatile var progress: Int = 0
    @Volatile var error: String = ""
    @Volatile var path: File? = null

    fun statusValue(): String = when (state) {
        "ready" -> "ready"
        // §6.4 truthfulness (E0001): the last chunk makes progress hit 100 while
        // still downloading (verify + atomic publish come after), so the
        // DOWNLOADING projection is capped at 99. 100 appears only as "ready",
        // after sha256 verify + atomic rename — never before completion.
        "downloading" -> "downloading:${if (progress >= 100) 99 else maxOf(0, progress)}%"
        "verifying" -> "verifying"
        "retrying" -> "retrying"
        "error" -> if (error.isNotEmpty()) "error:$error" else "error"
        else -> state
    }
}

/**
 * Background, resumable media downloader + sha256 verifier + cache map
 * (protocol_spec §6). Mirrors windows_player/downloader.py:
 *
 *   - partial downloads land in `<name>.part`, resumed via `Range: bytes=N-`;
 *   - on completion sha256 is verified (when the item provides it) and the file
 *     is atomically renamed into place;
 *   - cache state is exposed in the exact shape status.cache wants.
 *
 * Files are content-addressed by sha256 when available (identical media
 * de-dupes), else by item_id + extension.
 */
class Downloader(
    private val cacheDir: File,
    private val onChange: (() -> Unit)? = null,
    private val chunkSize: Int = 256 * 1024,
    timeoutSeconds: Long = 30,
    private val retryBaseDelayMs: Long = 1_000L,
    private val retryMaxDelayMs: Long = 30_000L,
    private val retryJitterMs: Long = 250L,
    private val maxRetryAttempts: Int = 5,
    /** Injectable real Call factory used by deterministic concurrency fixtures. */
    private val callFactory: Call.Factory? = null,
    /**
     * Diagnostic sink → PlayerService.logEvent so cache-path decisions land in
     * the **exported** player.log, not logcat. The last black-screen regression
     * was undiagnosable because download/verify/restore events only went to
     * `Log.w/i` (logcat), which the 4.4 boxes truncate. Prefixed `dl ` service-side.
     */
    private val logSink: ((String) -> Unit)? = null,
) {
    private val entries = ConcurrentHashMap<String, CacheEntry>()
    private val inFlight = ConcurrentHashMap<String, Long>()
    private val activeCalls = ConcurrentHashMap<String, Call>()
    private val generation = AtomicLong(0L)

    private fun log(msg: String) { logSink?.invoke(msg) }

    /** §6 cache quota. 0 = unlimited (never evict). Set by the service from
     *  Settings.cacheMaxBytes. The *effective* cap also factors free disk. */
    @Volatile private var quotaMaxBytes: Long = 0L

    /** Absolute paths that back the current playlist — NEVER evicted (§11). */
    @Volatile private var protectedPaths: Set<String> = emptySet()
    private val pool = BoundedDownloadExecutor(
        maxConcurrent = MAX_CONCURRENT_DOWNLOADS,
        maxQueued = MAX_QUEUED_DOWNLOADS,
    )
    @Volatile private var stopped = false

    private val client = OkHttpClient.Builder()
        .callTimeout(0, TimeUnit.SECONDS) // long downloads; rely on read timeout
        .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .build()

    init {
        cacheDir.mkdirs()
    }

    fun localPath(item: MediaItem): File {
        val name = item.name ?: item.itemId
        val ext = name.substringAfterLast('.', "").let { if (it.isEmpty()) "bin" else it }
        val stem = item.sha256 ?: item.itemId
        return File(cacheDir, "$stem.$ext")
    }

    fun cacheStatus(): Map<String, String> =
        entries.mapValues { it.value.statusValue() }

    fun isReady(itemId: String): Boolean =
        entries[itemId]?.state == "ready"

    fun readyPath(itemId: String): File? {
        val e = entries[itemId]
        return if (e?.state == "ready") e.path else null
    }

    /**
     * §27/§28 cache inventory: item_id -> on-disk path for every READY entry.
     * Mirrors windows_player/downloader.py `ready_paths()`. Pure read of the
     * in-memory index; the LiveCacheBackend uses it to enumerate what is
     * physically present so cleanup plans against the REAL cache, not metadata.
     */
    fun readyPaths(): Map<String, File> {
        val out = LinkedHashMap<String, File>()
        for ((id, e) in entries) {
            val p = e.path
            if (e.state == "ready" && p != null) out[id] = p
        }
        return out
    }

    /** True only for paths canonically contained by this downloader's cache root. */
    fun ownsPath(path: File): Boolean = try {
        val root = cacheDir.canonicalFile
        val candidate = path.canonicalFile
        candidate.path == root.path || candidate.path.startsWith(root.path + File.separator)
    } catch (_: Exception) {
        false
    }

    /** Atomically reject live download targets and remove a READY blob. */
    @Synchronized
    fun deleteReadyPathIfIdle(path: File): Boolean {
        if (!ownsPath(path)) return false
        val target = try { path.canonicalPath } catch (_: Exception) { path.absolutePath }
        for (e in entries.values) {
            val ep = e.path ?: continue
            val same = try { ep.canonicalPath == target } catch (_: Exception) {
                ep.absolutePath == target
            }
            if (same && e.state in setOf("pending", "downloading", "verifying", "retrying")) {
                return false
            }
        }
        return try { path.exists() && path.delete() && !path.exists() } catch (_: Exception) { false }
    }

    /**
     * §27 inflight protection: item_id -> partial path (or null) for entries
     * still being fetched/verified. Their `.part` must never be reclaimed under
     * a delete window (protection reason `inflight`). Mirrors Windows
     * `inflight_paths()`.
     */
    fun inflightPaths(): Map<String, File?> {
        val out = LinkedHashMap<String, File?>()
        for ((id, e) in entries) {
            if (e.state in setOf("pending", "downloading", "verifying", "retrying")) {
                out[id] = e.path
            }
        }
        return out
    }

    /**
     * §27/§28 index prune after a blob is physically deleted, so no cache row
     * keeps pointing at a removed file (dangling-alias bug). Mirrors Windows
     * `prune_entries()`. Delete of the file itself stays with the backend; this
     * only drops the in-memory rows for the given ids.
     */
    fun pruneEntries(itemIds: List<String>) {
        var changed = false
        for (id in itemIds) {
            if (entries.remove(id) != null) changed = true
            inFlight.remove(id)
        }
        if (changed) notifyChange()
    }

    /**
     * §10/§11 重启恢复:进程重来后 [entries] 是空的(纯内存索引),但媒体文件仍在
     * [cacheDir]。对给定 playlist 的每个 item,按 [localPath] 算出期望文件路径,
     * 若文件已存在且(有 size 时)大小匹配、且没有对应的 `.part` 未完成文件,就在
     * [entries] 里登记为 ready —— 使 [readyPath] 重启后仍能命中磁盘缓存,而不是回退到
     * 早已失效的 `item.url`(黑屏根因)。
     *
     * 纯**读**操作:只 stat 文件、写内存索引,不碰磁盘内容(不违反假闪存防过度写红线)。
     * 已是 ready 的 item 跳过;已在下载中的 item 不动。返回本次新登记的条数。
     */
    fun restoreReadyFromDisk(items: List<MediaItem>): Int {
        var restored = 0
        for (item in items) {
            val itemId = item.itemId
            // 已 ready 或正在处理 → 别覆盖内存里的活状态。
            val cur = entries[itemId]
            if (cur != null && cur.state in setOf("ready", "downloading", "verifying")) continue
            if (inFlight.containsKey(itemId)) continue
            val target = localPath(item)
            val part = File(target.parentFile, target.name + ".part")
            // 完整文件必须存在、无对应 .part、且大小匹配(有 size 时)才算 ready。
            if (!target.exists() || part.exists()) continue
            val size = item.size
            if (size != null && target.length() != size) {
                log("restore skip=$itemId reason=size-mismatch disk=${target.length()} expect=$size")
                continue
            }
            // B2 根因修复:重启恢复捷径过去只比 size 就标 ready,一个被截断/损坏但
            // 长度恰好相符(或 item 未带 size)的文件会被当作可播 —— ExoPlayer 拿到坏
            // 码流吐 OMX_ErrorStreamCorrupt → 黑屏。带 sha256 的 item 恢复前必须校验;
            // 不符则删文件回退完整下载,绝不标 ready。size-only 的旧行为仅在 item 没有
            // sha256(无法校验)时保留,并显式记 unverified 供诊断。
            val expectedSha = item.sha256
            if (!expectedSha.isNullOrEmpty()) {
                val actual = try {
                    sha256File(target)
                } catch (e: Exception) {
                    log("restore skip=$itemId reason=sha-read-fail:${e.javaClass.simpleName}")
                    continue
                }
                if (!actual.equals(expectedSha, ignoreCase = true)) {
                    log("restore reject=$itemId reason=sha256-mismatch " +
                        "actual=${actual.take(12)} expect=${expectedSha.take(12)} → delete+refetch")
                    target.delete() // corrupt on disk; force a clean re-download
                    continue
                }
                log("restore ok=$itemId source=disk sha256=verified size=${target.length()}")
            } else {
                log("restore ok=$itemId source=disk sha256=UNVERIFIED(item has no sha) size=${target.length()}")
            }
            entries[itemId] = CacheEntry(itemId).apply {
                state = "ready"; progress = 100; path = target
            }
            restored++
        }
        if (restored > 0) notifyChange()
        return restored
    }

    /** Queue a batch (§6.2). Ready items are skipped; others get a worker. */
    fun prefetch(items: List<MediaItem>) {
        // §6 假闪存红线:拉新内容**之前**先给真实颗粒腾余量,顺序很重要 ——
        //  1) 孤儿回收:删掉不再被任何活跃 playlist 引用的旧媒体(reclaimOrphans
        //     由 service 在收到新 playlist 时先调好,这里只做配额兜底);
        //  2) 配额 LRU:超出保守硬上限的部分按 LRU 删;
        //  3) 写前探针:因为不能信 usableSpace,真写一小块验证闪存还能写 —— 探不过
        //     就判定真实空间已满,跳过这批下载(受保护的当前 playlist 若已缓存则照播,
        //     不缓存也不会因灌爆假容量把盒子写坏)。
        // Protect what the incoming batch will reference so we don't evict a file
        // we're about to (re)use.
        enforceQuota(extraProtected = items.map { localPath(it).absolutePath })
        if (!probeWritable()) {
            Log.w(TAG, "prefetch skipped: write-probe failed (real flash full?) — " +
                "reclaim ran, not writing new media to a fake-capacity volume")
            return
        }
        for (item in items) ensureEntryAndStart(item, DownloadPriority.BACKGROUND)
    }

    /** Current/prepare misses use the foreground lane and promote queued work. */
    fun prefetchForeground(item: MediaItem) {
        enforceQuota(extraProtected = listOf(localPath(item).absolutePath))
        if (probeWritable()) ensureEntryAndStart(item, DownloadPriority.FOREGROUND)
    }

    /**
     * §6 假闪存红线:反向验证**真实可写空间**。因为 `usableSpace` 在假容量盒子上是
     * 假的,不能信它放行写入 —— 这里真写一个小测试文件、fsync、读回校验、删除。写失败
     * 或校验不符 → 真实颗粒已满,返回 false 让调用方停止写入。
     *
     * 探针刻意**轻量、低频**(每次 prefetch 批次一次,不是每文件),用完即删,自身
     * 不产生持续写量(防过度写自身红线)。unlimited(quota=0)时跳过探针(operator
     * 明确要求不限,不替他做主)。
     */
    private fun probeWritable(): Boolean {
        if (quotaMaxBytes <= 0L) return true // unlimited: operator opted out
        val probe = File(cacheDir, ".lmw_write_probe")
        return try {
            val payload = ByteArray(PROBE_BYTES) { (it and 0x7f).toByte() }
            java.io.FileOutputStream(probe).use { fos ->
                fos.write(payload)
                fos.flush()
                fos.fd.sync() // force to real颗粒, not just page cache
            }
            // read back + verify a fake-capacity volume didn't silently drop it.
            val readBack = probe.readBytes()
            readBack.size == payload.size && readBack.first() == payload.first() &&
                readBack.last() == payload.last()
        } catch (e: Exception) {
            Log.w(TAG, "write-probe failed: ${e.javaClass.simpleName}")
            false
        } finally {
            try { probe.delete() } catch (_: Exception) {}
        }
    }

    /**
     * §6 主动清理孤儿媒体(新):删掉**不再被任何活跃 playlist 引用**的缓存文件,给
     * 假闪存腾真实余量。由 service 在收到新 playlist/prepare 时、拉新内容之前调用。
     *
     * [referencedPaths] 是所有仍需保留的媒体的绝对路径(当前 + 最近 N 条 playlist +
     * last_task 指向的)。protected 路径、`.part` 在传文件、探针文件永不回收(黑屏红线)。
     * 纯**读+删**,不产生额外写。返回删除的文件数。
     */
    @Synchronized
    fun reclaimOrphans(referencedPaths: Set<String>): Int {
        val protectedNow = HashSet(protectedPaths)
        val onDisk = cacheDir.listFiles()?.filter { it.isFile } ?: return 0
        val files = onDisk.map { f ->
            val abs = f.absolutePath
            val isPart = f.name.endsWith(".part")
            val isProbe = f.name == ".lmw_write_probe"
            CacheEviction.CacheFile(
                id = abs,
                sizeBytes = f.length(),
                lastAccessMs = f.lastModified(),
                // never reclaim: .part in flight, the probe file, protected media.
                protected = isPart || isProbe || protectedNow.contains(abs),
            )
        }
        val orphans = CacheEviction.selectOrphans(files, referencedPaths)
        if (orphans.isEmpty()) return 0
        var deleted = 0
        var freed = 0L
        for (path in orphans) {
            val f = File(path)
            val len = f.length()
            if (f.delete()) {
                deleted++
                freed += len
                val it = entries.entries.iterator()
                while (it.hasNext()) {
                    if (it.next().value.path?.absolutePath == path) it.remove()
                }
            }
        }
        if (deleted > 0) {
            Log.i(TAG, "orphan reclaim: freed ~${freed / (1024 * 1024)}MB " +
                "($deleted/${orphans.size} unreferenced files)")
            notifyChange()
        }
        return deleted
    }

    /**
     * §6 quota configuration. [maxBytes] is the operator cap (0 = unlimited);
     * [protectedFiles] are absolute paths backing the current playlist that
     * must never be evicted. Called by the service on playlist/prepare changes.
     */
    fun configureQuota(maxBytes: Long, protectedFiles: Set<String>) {
        quotaMaxBytes = maxBytes
        protectedPaths = protectedFiles
    }

    /** Mark a file as just-used so LRU eviction keeps it (updates mtime). */
    fun touch(path: File) {
        try { if (path.exists()) path.setLastModified(System.currentTimeMillis()) }
        catch (_: Exception) {}
    }

    /**
     * §6 LRU eviction pass. Scans the cache dir, computes the effective quota
     * (operator cap ∩ %-of-free-disk), and deletes least-recently-accessed
     * files until under quota — never touching protected paths, in-flight
     * `.part` files, or the current playlist's media. Safe to call often; a
     * no-op when unlimited or already under quota.
     */
    @Synchronized
    fun enforceQuota(extraProtected: List<String> = emptyList()) {
        val cap = quotaMaxBytes
        if (cap <= 0L) return // unlimited
        val protectedNow = HashSet(protectedPaths).apply { addAll(extraProtected) }
        val readyPaths = entries.values.mapNotNull { it.path?.absolutePath }.toHashSet()

        val onDisk = cacheDir.listFiles()?.filter { it.isFile } ?: return
        val currentBytes = onDisk.sumOf { it.length() }
        val usable = try { cacheDir.usableSpace } catch (_: Exception) { Long.MAX_VALUE }
        val quota = CacheEviction.effectiveQuota(
            configuredMaxBytes = cap,
            usableSpaceBytes = usable,
            currentCacheBytes = currentBytes,
        )

        val files = onDisk.map { f ->
            val abs = f.absolutePath
            // Never evict: protected playlist media, or an in-progress .part.
            val isPart = f.name.endsWith(".part")
            val prot = isPart || protectedNow.contains(abs)
            CacheEviction.CacheFile(
                id = abs,
                sizeBytes = f.length(),
                lastAccessMs = f.lastModified(),
                protected = prot,
            )
        }
        val plan = CacheEviction.selectEvictions(files, quota)
        if (plan.evict.isEmpty()) return

        var deleted = 0
        for (path in plan.evict) {
            val f = File(path)
            if (f.delete()) {
                deleted++
                // drop any cache entry pointing at the deleted file so a later
                // prepare re-fetches it instead of trusting a dead path.
                // NB: MutableMap.entries.removeIf is API 24+ — use an explicit
                // iterator so this is safe on API 19 (§6) without desugaring a
                // platform collection method.
                val it = entries.entries.iterator()
                while (it.hasNext()) {
                    if (it.next().value.path?.absolutePath == path) it.remove()
                }
                if (readyPaths.contains(path)) { /* was ready; entry pruned above */ }
            }
        }
        Log.i(TAG, "cache eviction: freed ~${plan.freedBytes / (1024 * 1024)}MB " +
            "(deleted $deleted/${plan.evict.size} files; " +
            "${plan.totalBefore / (1024 * 1024)}MB→${plan.totalAfter / (1024 * 1024)}MB, " +
            "quota=${quota / (1024 * 1024)}MB)")
        notifyChange()
    }

    private fun ensureEntryAndStart(item: MediaItem, priority: DownloadPriority) {
        val itemId = item.itemId
        val target = localPath(item)
        var token = 0L
        synchronized(this) {
            if (stopped) {
                entries[itemId] = CacheEntry(itemId).apply { state = "error"; error = "stopped" }
                return
            }
            val existing = entries[itemId]
            if (existing != null && existing.state in setOf("downloading", "verifying", "retrying")) return
            if (inFlight.containsKey(itemId)) {
                pool.submit(itemId, priority) { }
                return
            }
            if (target.exists() && quickOk(target, item)) {
                val expectedSha = item.sha256
                if (!expectedSha.isNullOrEmpty()) {
                    val actual = try { sha256File(target) } catch (_: Exception) { null }
                    if (actual == null || !actual.equals(expectedSha, ignoreCase = true)) {
                        log("prefetch reject=$itemId reason=sha256-mismatch → delete+refetch")
                        target.delete()
                    } else {
                        entries[itemId] = CacheEntry(itemId).apply {
                            state = "ready"; progress = 100; path = target
                        }
                        notifyChange()
                        return
                    }
                } else {
                    entries[itemId] = CacheEntry(itemId).apply {
                        state = "ready"; progress = 100; path = target
                    }
                    notifyChange()
                    return
                }
            }
            token = generation.incrementAndGet()
            entries[itemId] = CacheEntry(itemId).apply { path = target }
            inFlight[itemId] = token
        }
        val result = pool.submit(
            itemId,
            priority,
            onCancelled = { cancelToken(itemId, token, "stopped") },
        ) { worker(item, token) }
        if (result == SubmitResult.REJECTED) cancelToken(itemId, token, if (stopped) "stopped" else "queue-full")
    }

    private fun cancelToken(itemId: String, token: Long, reason: String) {
        synchronized(this) {
            if (inFlight[itemId] != token) return
            inFlight.remove(itemId)
            val e = entries.getOrPut(itemId) { CacheEntry(itemId) }
            e.state = "error"
            e.error = reason
        }
        notifyChange()
    }

    private fun quickOk(path: File, item: MediaItem): Boolean {
        val size = item.size
        if (size != null && path.length() != size) return false
        return true
    }

    private fun worker(item: MediaItem, token: Long) {
        val itemId = item.itemId
        val target = localPath(item)
        val part = File(target.parentFile, target.name + ".part")
        try {
            var attempt = 0
            while (!stopped) {
                var existing = if (part.exists()) part.length() else 0L
                val builder = Request.Builder().url(item.url).get()
                RangeMath.rangeHeader(existing)?.let { builder.header("Range", it) }
                val call = synchronized(this) {
                    if (stopped || inFlight[itemId] != token) return
                    val created = (callFactory ?: client).newCall(builder.build())
                    // Creation and publication are owned by the same lifecycle lock as stop.
                    // stop therefore either runs first (no Call is created), or observes and
                    // cancels this exact Call before it can escape into execute().
                    activeCalls[itemId] = created
                    created
                }
                val retryDelay = call.execute().use { resp ->
                    activeCalls.remove(itemId, call)
                    val code = resp.code()
                    if (code == 429 || code == 503) {
                        if (attempt >= maxRetryAttempts) {
                            failIfCurrent(itemId, token, "http-$code")
                            return
                        }
                        attempt++
                        retryDelayMs(resp.header("Retry-After"), attempt)
                    } else {
                        if (code != 200 && code != 206) {
                            failIfCurrent(itemId, token, "http-$code")
                            return
                        }
                        if (code == 200 && existing > 0) {
                            existing = 0
                            part.delete()
                        }
                        val clen = resp.header("Content-Length")?.toLongOrNull()
                        val crTotal = RangeMath.parseContentRangeTotal(resp.header("Content-Range"))
                        val total = RangeMath.expectedTotal(existing, code, clen, crTotal) ?: item.size
                        var downloaded = existing
                        setIfCurrent(itemId, token, state = "downloading", progress = RangeMath.percent(downloaded, total))
                        val body = resp.body() ?: run { failIfCurrent(itemId, token, "no-body"); return }
                        java.io.FileOutputStream(part, existing > 0).use { fos ->
                            val src = body.byteStream()
                            val buf = ByteArray(chunkSize)
                            while (!stopped) {
                                val n = src.read(buf)
                                if (n < 0) break
                                if (n == 0) continue
                                fos.write(buf, 0, n)
                                downloaded += n
                                setIfCurrent(itemId, token, state = "downloading",
                                    progress = RangeMath.percent(downloaded, total))
                            }
                        }
                        if (stopped) return
                        null
                    }
                }
                if (retryDelay == null) break
                setIfCurrent(itemId, token, state = "retrying")
                log("download retry=$itemId attempt=$attempt delay_ms=$retryDelay")
                if (!sleepInterruptibly(retryDelay)) return
            }
            if (stopped) return
            setIfCurrent(itemId, token, state = "verifying")
            val expectedSha = item.sha256
            if (!expectedSha.isNullOrEmpty()) {
                val actual = sha256File(part)
                if (!actual.equals(expectedSha, ignoreCase = true)) {
                    part.delete()
                    failIfCurrent(itemId, token, "sha256-mismatch")
                    return
                }
            }
            synchronized(this) {
                if (inFlight[itemId] != token || stopped) return
                if (!part.renameTo(target)) {
                    part.copyTo(target, overwrite = true)
                    part.delete()
                }
                val e = entries.getOrPut(itemId) { CacheEntry(itemId) }
                e.state = "ready"; e.progress = 100; e.path = target
            }
            notifyChange()
        } catch (e: Exception) {
            activeCalls.remove(itemId)
            if (!stopped) failIfCurrent(itemId, token, e.javaClass.simpleName)
        } finally {
            if (stopped) cancelToken(itemId, token, "stopped")
            else synchronized(this) { if (inFlight[itemId] == token) inFlight.remove(itemId) }
        }
    }

    private fun retryDelayMs(header: String?, attempt: Int): Long {
        val retryAfterMs = header?.trim()?.toLongOrNull()?.coerceIn(0L, 60L)?.times(1_000L)
        val shift = min(attempt - 1, 20)
        val exponential = retryBaseDelayMs * (1L shl shift)
        val base = min(retryMaxDelayMs, retryAfterMs ?: exponential)
        val jitter = if (retryJitterMs > 0) Random.nextLong(retryJitterMs + 1) else 0L
        return min(retryMaxDelayMs, base + jitter)
    }

    private fun sleepInterruptibly(delayMs: Long): Boolean {
        var remaining = delayMs
        while (!stopped && remaining > 0) {
            val slice = min(remaining, 100L)
            try { Thread.sleep(slice) } catch (_: InterruptedException) { return false }
            remaining -= slice
        }
        return !stopped
    }

    private fun sha256File(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { ins ->
            val buf = ByteArray(1024 * 1024)
            while (true) {
                val n = ins.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun setIfCurrent(
        itemId: String, token: Long, state: String? = null, progress: Int? = null,
        error: String? = null, path: File? = null,
    ) {
        synchronized(this) {
            if (inFlight[itemId] != token || stopped) return
            val e = entries.getOrPut(itemId) { CacheEntry(itemId) }
            state?.let { e.state = it }
            progress?.let { e.progress = it }
            error?.let { e.error = it }
            path?.let { e.path = it }
        }
        notifyChange()
    }

    private fun failIfCurrent(itemId: String, token: Long, err: String) {
        setIfCurrent(itemId, token, state = "error", error = err)
    }

    private fun notifyChange() {
        try { onChange?.invoke() } catch (_: Exception) {}
    }

    fun stop() {
        stopAndAwait(STOP_AWAIT_MS)
    }

    /**
     * Close the downloader and wait until every bounded worker has exited.
     * The stopped transition shares [this] with Call creation/publication, so
     * the captured list is complete: no worker can publish a new Call after it.
     */
    fun stopAndAwait(timeoutMs: Long): Boolean {
        val calls = synchronized(this) {
            stopped = true
            activeCalls.values.toList()
        }
        calls.forEach { try { it.cancel() } catch (_: Exception) {} }
        client.dispatcher().cancelAll()
        pool.shutdownNow()
        val terminated = pool.awaitTermination(timeoutMs)
        val leftovers = synchronized(this) { inFlight.toMap() }
        leftovers.forEach { (itemId, token) -> cancelToken(itemId, token, "stopped") }
        return terminated
    }

    companion object {
        private const val TAG = "lmw.Downloader"
        /** Keep per-player network/disk pressure bounded during large playlists. */
        private const val MAX_CONCURRENT_DOWNLOADS = 2
        /** Bound retained lambdas/items; excess work fails visibly as queue-full. */
        private const val MAX_QUEUED_DOWNLOADS = 64
        /** Bound service teardown without relying on high-API lifecycle primitives. */
        private const val STOP_AWAIT_MS = 5_000L
        /** §6 写前探针大小:够小以免自身造成过度写,够大以真触达闪存写路径。4 MiB。 */
        private const val PROBE_BYTES = 4 * 1024 * 1024
    }
}
