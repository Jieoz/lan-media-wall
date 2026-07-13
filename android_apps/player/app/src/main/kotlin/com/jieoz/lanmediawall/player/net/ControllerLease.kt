package com.jieoz.lanmediawall.player.net

/**
 * Thread-safe single-controller ownership with a bounded inactivity lease.
 *
 * Time values must come from a monotonic clock. [Owner.generation] makes release
 * and renewal safe when an old receive thread finishes after a stale takeover.
 */
class ControllerLease<T>(private val leaseMs: Long) {
    init {
        require(leaseMs > 0) { "leaseMs must be positive" }
    }

    data class Owner<T>(val value: T, val generation: Long)

    sealed class Acquire<T> {
        data class Acquired<T>(val owner: Owner<T>) : Acquire<T>()
        data class Rejected<T>(val active: Owner<T>) : Acquire<T>()
        data class Replaced<T>(val owner: Owner<T>, val stale: Owner<T>) : Acquire<T>()
    }

    private var owner: Owner<T>? = null
    private var lastActivity = 0L
    private var nextGeneration = 1L

    @Synchronized
    fun acquire(value: T, nowMs: Long): Acquire<T> {
        val old = owner
        if (old != null && nowMs - lastActivity < leaseMs) return Acquire.Rejected(old)
        val fresh = Owner(value, nextGeneration++)
        owner = fresh
        lastActivity = nowMs
        return if (old == null) Acquire.Acquired(fresh) else Acquire.Replaced(fresh, old)
    }

    @Synchronized
    fun renew(candidate: Owner<T>, nowMs: Long): Boolean {
        if (owner?.generation != candidate.generation) return false
        lastActivity = nowMs
        return true
    }

    @Synchronized
    fun release(candidate: Owner<T>): Boolean {
        if (owner?.generation != candidate.generation) return false
        owner = null
        return true
    }

    @Synchronized
    fun currentOwner(): Owner<T>? = owner

    @Synchronized
    fun current(): T? = owner?.value

    @Synchronized
    fun lastActivityMs(): Long = lastActivity
}
