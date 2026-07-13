package com.jieoz.lanmediawall.player

/**
 * API-19-compatible ownership gate for asynchronous prepare barriers.
 *
 * Generation replacement/cancellation and the winning waiter's prime + ready
 * effects share this monitor.  Therefore replacement can happen before an old
 * waiter acquires ownership (and suppress it), or after its complete effect
 * block, but never in the check-to-effect window.
 */
class PrepareGeneration {
    private var value = 0L

    @Synchronized
    fun replace(): Long {
        value += 1L
        return value
    }

    @Synchronized
    fun cancel() {
        value += 1L
    }

    @Synchronized
    fun isCurrent(token: Long): Boolean = value == token

    @Synchronized
    fun runIfCurrent(token: Long, effects: () -> Unit): Boolean {
        if (value != token) return false
        effects()
        return true
    }
}
