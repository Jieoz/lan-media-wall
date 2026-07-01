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
) {
    private val entries = ConcurrentHashMap<String, CacheEntry>()
    private val inFlight = ConcurrentHashMap<String, Boolean>()

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

    /** Queue a batch (§6.2). Ready items are skipped; others get a worker. */
    fun prefetch(items: List<MediaItem>) {
        // §6: reclaim space before pulling new media so a churning wall never
        // hits Storage Full. Protect what the incoming batch will reference so
        // we don't evict a file we're about to (re)use.
        enforceQuota(extraProtected = items.map { localPath(it).absolutePath })
        for (item in items) ensureEntryAndStart(item)
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
                entries.entries.removeIf { it.value.path?.absolutePath == path }
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
                val e = CacheEntry(itemId).apply {
                    state = "ready"; progress = 100; path = target
                }
                entries[itemId] = e
                notifyChange()
                return
            }
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
                val code = resp.code
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

                val body = resp.body ?: run { fail(itemId, "no-body"); return }
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
                    part.delete() // corrupt; force clean retry
                    fail(itemId, "sha256-mismatch")
                    return
                }
            }
            if (!part.renameTo(target)) {
                // fallback: copy+delete if rename across boundary fails
                part.copyTo(target, overwrite = true)
                part.delete()
            }
            set(itemId, state = "ready", progress = 100, path = target)
        } catch (e: Exception) {
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
    }
}
