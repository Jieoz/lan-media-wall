package com.jieoz.lanmediawall.player.cache

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Bounded media-download executor. Both active workers and queued work are
 * capped so a large playlist cannot amplify into unbounded threads or memory.
 */
class BoundedDownloadExecutor(maxConcurrent: Int, maxQueued: Int) {
    init {
        require(maxConcurrent > 0) { "maxConcurrent must be positive" }
        require(maxQueued > 0) { "maxQueued must be positive" }
    }

    private val executor = ThreadPoolExecutor(
        maxConcurrent,
        maxConcurrent,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(maxQueued),
        { r -> Thread(r, "dl-worker").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy(),
    )

    val queued: Int get() = executor.queue.size

    fun submit(task: () -> Unit): Boolean = try {
        executor.execute(task)
        true
    } catch (_: java.util.concurrent.RejectedExecutionException) {
        false
    }

    fun shutdownNow() {
        executor.shutdownNow()
    }
}
