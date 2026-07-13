package com.jieoz.lanmediawall.player

import java.util.concurrent.atomic.AtomicLong

/**
 * Tiny API-19-compatible identity guard for asynchronous prepare barriers.
 * Every replace/cancel advances the token; a stale coroutine must check its
 * captured token before touching the decoder or reporting ready.
 */
class PrepareGeneration {
    private val value = AtomicLong(0L)

    fun replace(): Long = value.incrementAndGet()

    fun cancel() {
        value.incrementAndGet()
    }

    fun isCurrent(token: Long): Boolean = value.get() == token
}
