package com.jieoz.lanmediawall.player.cache

import okhttp3.OkHttpClient
import okhttp3.Request
import android.util.Log
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

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
        "downloading" -> "downloading:$progress%"
        "verifying" -> "verifying"
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
    /**
     * Diagnostic sink → PlayerService.logEvent so cache-path decisions land in
     * the **exported** player.log, not logcat. The last black-screen regression
     * was undiagnosable because download/verify/restore events only went to
     * `Log.w/i` (logcat), which the 4.4 boxes truncate. Prefixed `dl ` service-side.
     */
    private val logSink: ((String) -> Unit)? = null,
) {
    private val entries = ConcurrentHashMap<String, CacheEntry>()
    private val inFlight = ConcurrentHashMap<String, Boolean>()

    private fun log(msg: String) { logSink?.invoke(msg) }

    /** §6 cache quota. 0 = unlimited (never evict). Set by the service from
     *  Settings.cacheMaxBytes. The *effective* cap also factors free disk. */
    @Volatile private var quotaMaxBytes: Long = 0L

    /** Absolute paths that back the current playlist — NEVER evicted (§11). */
    @Volatile private var protectedPaths: Set<String> = emptySet()
    private val pool = Executors.newCachedThreadPool { r ->
        Thread(r, "dl-worker").apply { isDaemon = true }
    }
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
            if (inFlight[itemId] == true) continue
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
        for (item in items) ensureEntryAndStart(item)
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

    private fun ensureEntryAndStart(item: MediaItem) {
        val itemId = item.itemId
        val target = localPath(item)
        synchronized(this) {
            val existing = entries[itemId]
            if (existing != null && existing.state in setOf("downloading", "verifying")) return
            if (inFlight[itemId] == true) return
            if (target.exists() && quickOk(target, item)) {
                // B2 根因修复(第二处 size-only 捷径):prefetch 命中磁盘旧文件时,过去
                // 仅 quickOk(比 size)就直接标 ready,和 restoreReadyFromDisk 同源。带
                // sha256 的 item 必须校验通过才认 ready;不符删文件走完整下载。
                val expectedSha = item.sha256
                if (!expectedSha.isNullOrEmpty()) {
                    val actual = try { sha256File(target) } catch (e: Exception) { null }
                    if (actual == null || !actual.equals(expectedSha, ignoreCase = true)) {
                        log("prefetch reject=$itemId reason=sha256-mismatch " +
                            "actual=${actual?.take(12) ?: "read-fail"} expect=${expectedSha.take(12)} → delete+refetch")
                        target.delete()
                        entries[itemId] = CacheEntry(itemId)
                        inFlight[itemId] = true
                        pool.submit { worker(item) }
                        return
                    }
                    log("prefetch ok=$itemId source=disk sha256=verified size=${target.length()}")
                } else {
                    log("prefetch ok=$itemId source=disk sha256=UNVERIFIED(item has no sha) size=${target.length()}")
                }
                val e = CacheEntry(itemId).apply {
                    state = "ready"; progress = 100; path = target
                }
                entries[itemId] = e
                notifyChange()
                return
            }
            log("prefetch start=$itemId source=network url=${item.url}")
            entries[itemId] = CacheEntry(itemId)
            inFlight[itemId] = true
        }
        pool.submit { worker(item) }
    }

    private fun quickOk(path: File, item: MediaItem): Boolean {
        val size = item.size
        if (size != null && path.length() != size) return false
        return true
    }

    private fun worker(item: MediaItem) {
        val itemId = item.itemId
        val target = localPath(item)
        val part = File(target.parentFile, target.name + ".part")
        try {
            var existing = if (part.exists()) part.length() else 0L
            val builder = Request.Builder().url(item.url).get()
            RangeMath.rangeHeader(existing)?.let { builder.header("Range", it) }

            client.newCall(builder.build()).execute().use { resp ->
                // okhttp 3.12: Response exposes code()/body()/header() as
                // methods (okhttp 4 turned them into Kotlin properties).
                val code = resp.code()
                if (code != 200 && code != 206) {
                    fail(itemId, "http-$code")
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
                set(itemId, state = "downloading", progress = RangeMath.percent(downloaded, total))

                val body = resp.body() ?: run { fail(itemId, "no-body"); return }
                val append = existing > 0
                val out = java.io.FileOutputStream(part, append)
                out.use { fos ->
                    val src = body.byteStream()
                    val buf = ByteArray(chunkSize)
                    while (true) {
                        if (stopped) return // leave .part for next resume
                        val n = src.read(buf)
                        if (n < 0) break
                        if (n == 0) continue
                        fos.write(buf, 0, n)
                        downloaded += n
                        set(itemId, state = "downloading",
                            progress = RangeMath.percent(downloaded, total))
                    }
                }
            }

            // verify
            set(itemId, state = "verifying")
            val expectedSha = item.sha256
            if (!expectedSha.isNullOrEmpty()) {
                val actual = sha256File(part)
                if (!actual.equals(expectedSha, ignoreCase = true)) {
                    log("download reject=$itemId reason=sha256-mismatch " +
                        "actual=${actual.take(12)} expect=${expectedSha.take(12)} bytes=${part.length()}")
                    part.delete() // corrupt; force clean retry
                    fail(itemId, "sha256-mismatch")
                    return
                }
                log("download verified=$itemId source=network sha256=ok bytes=${part.length()}")
            } else {
                log("download done=$itemId source=network sha256=UNVERIFIED(item has no sha) bytes=${part.length()}")
            }
            if (!part.renameTo(target)) {
                // fallback: copy+delete if rename across boundary fails
                part.copyTo(target, overwrite = true)
                part.delete()
            }
            set(itemId, state = "ready", progress = 100, path = target)
        } catch (e: Exception) {
            log("download fail=$itemId ex=${e.javaClass.simpleName}:${e.message}")
            fail(itemId, e.javaClass.simpleName) // keep .part for resume
        } finally {
            inFlight.remove(itemId)
        }
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

    private fun set(
        itemId: String, state: String? = null, progress: Int? = null,
        error: String? = null, path: File? = null,
    ) {
        val e = entries.getOrPut(itemId) { CacheEntry(itemId) }
        state?.let { e.state = it }
        progress?.let { e.progress = it }
        error?.let { e.error = it }
        path?.let { e.path = it }
        notifyChange()
    }

    private fun fail(itemId: String, err: String) {
        set(itemId, state = "error", error = err)
    }

    private fun notifyChange() {
        try { onChange?.invoke() } catch (_: Exception) {}
    }

    fun stop() {
        stopped = true
        pool.shutdownNow()
    }

    companion object {
        private const val TAG = "lmw.Downloader"
        /** §6 写前探针大小:够小以免自身造成过度写,够大以真触达闪存写路径。4 MiB。 */
        private const val PROBE_BYTES = 4 * 1024 * 1024
    }
}
