package com.jieoz.lanmediawall.player.cache

import java.util.ArrayDeque
import java.util.HashMap

/** Priority used by the two-lane bounded media scheduler. */
enum class DownloadPriority { FOREGROUND, BACKGROUND }

enum class SubmitResult { ACCEPTED, PROMOTED, DUPLICATE, REJECTED }

/**
 * API-19-compatible bounded scheduler with a fixed worker count and two FIFO
 * lanes. A queued background item can be promoted without creating a duplicate.
 */
class BoundedDownloadExecutor(
    maxConcurrent: Int,
    private val maxQueued: Int,
) {
    init {
        require(maxConcurrent > 0) { "maxConcurrent must be positive" }
        require(maxQueued > 0) { "maxQueued must be positive" }
    }

    private class Task(
        val itemId: String,
        val run: () -> Unit,
        val onCancelled: () -> Unit,
    )

    private val foreground = ArrayDeque<Task>()
    private val background = ArrayDeque<Task>()
    private val pending = HashMap<String, Task>()
    private val active = HashMap<String, Task>()
    private var closed = false
    private val workers = ArrayList<Thread>(maxConcurrent)

    init {
        repeat(maxConcurrent) { workerIndex ->
            val thread = Thread({ workerLoop() }, "dl-worker-${workerIndex + 1}")
            thread.isDaemon = true
            workers.add(thread)
            thread.start()
        }
    }

    val queued: Int get() = synchronized(this) { pending.size }

    fun contains(itemId: String): Boolean = synchronized(this) {
        pending.containsKey(itemId) || active.containsKey(itemId)
    }

    @JvmOverloads
    fun submit(
        itemId: String,
        priority: DownloadPriority,
        onCancelled: () -> Unit = {},
        task: () -> Unit,
    ): SubmitResult = synchronized(this) {
        if (closed) return@synchronized SubmitResult.REJECTED
        if (active.containsKey(itemId)) return@synchronized SubmitResult.DUPLICATE
        val old = pending[itemId]
        if (old != null) {
            if (priority == DownloadPriority.FOREGROUND && background.remove(old)) {
                foreground.addLast(old)
                (this as java.lang.Object).notifyAll()
                return@synchronized SubmitResult.PROMOTED
            }
            return@synchronized SubmitResult.DUPLICATE
        }
        if (pending.size >= maxQueued) return@synchronized SubmitResult.REJECTED
        val queuedTask = Task(itemId, task, onCancelled)
        pending[itemId] = queuedTask
        if (priority == DownloadPriority.FOREGROUND) foreground.addLast(queuedTask)
        else background.addLast(queuedTask)
        (this as java.lang.Object).notifyAll()
        SubmitResult.ACCEPTED
    }

    private fun workerLoop() {
        while (true) {
            val task = synchronized(this) {
                while (!closed && foreground.isEmpty() && background.isEmpty()) {
                    try { (this as java.lang.Object).wait() }
                    catch (_: InterruptedException) { if (closed) return }
                }
                if (closed) return
                val next = if (foreground.isNotEmpty()) foreground.removeFirst()
                    else background.removeFirst()
                pending.remove(next.itemId)
                active[next.itemId] = next
                next
            }
            try {
                task.run()
            } finally {
                synchronized(this) { active.remove(task.itemId) }
            }
        }
    }

    fun shutdownNow() {
        val queuedToCancel: List<Task>
        val activeToCancel: List<Task>
        synchronized(this) {
            if (closed) return
            closed = true
            queuedToCancel = pending.values.toList()
            activeToCancel = active.values.toList()
            foreground.clear()
            background.clear()
            pending.clear()
            (this as java.lang.Object).notifyAll()
        }
        queuedToCancel.forEach { safelyCancel(it) }
        activeToCancel.forEach { safelyCancel(it) }
        workers.forEach { it.interrupt() }
    }

    /** Wait until every worker has observed shutdown. Test/release lifecycle gate. */
    fun awaitTermination(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs.coerceAtLeast(0L)
        for (worker in workers) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0L && worker.isAlive) return false
            try { worker.join(remaining.coerceAtLeast(1L)) }
            catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        return workers.none { it.isAlive }
    }

    private fun safelyCancel(task: Task) {
        try { task.onCancelled() } catch (_: Exception) {}
    }
}
