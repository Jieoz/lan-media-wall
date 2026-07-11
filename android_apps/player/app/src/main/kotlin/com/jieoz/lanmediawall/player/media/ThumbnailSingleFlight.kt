package com.jieoz.lanmediawall.player.media

import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean

class ThumbnailSingleFlight {
    private val busy = AtomicBoolean(false)

    fun tryAcquire(): Closeable? {
        if (!busy.compareAndSet(false, true)) return null
        val closed = AtomicBoolean(false)
        return Closeable {
            if (closed.compareAndSet(false, true)) busy.set(false)
        }
    }
}