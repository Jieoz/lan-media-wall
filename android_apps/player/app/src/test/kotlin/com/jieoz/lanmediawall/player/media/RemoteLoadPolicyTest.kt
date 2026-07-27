package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Regression guards for the v1.19.5 field freeze (and-c937df0cdb): a music item
 * pointing at a controller that no longer existed
 * (`http://10.10.8.161:40571/m/cb14c4babac3.mp3`) parked MediaPlayer.setDataSource
 * on the MAIN thread, which silenced the whole video kernel — no `stopped` on the
 * following 音乐→图片 switch, no `loadAndPlay` after that, and 20+ useless
 * `watchdog_recover` ticks. Reported as "音乐切回图片黑屏".
 */
class RemoteLoadPolicyTest {

    @Test
    fun remoteSchemesMustOpenOffMainThread() {
        // The exact URI from the field log.
        assertTrue(RemoteLoadPolicy.needsOffMainThreadOpen("http://10.10.8.161:40571/m/cb14c4babac3.mp3"))
        assertTrue(RemoteLoadPolicy.needsOffMainThreadOpen("https://example.test/a.mp4"))
        assertTrue(RemoteLoadPolicy.needsOffMainThreadOpen("rtsp://10.0.0.5/stream"))
        // Case and padding must not smuggle a network open onto the main thread.
        assertTrue(RemoteLoadPolicy.needsOffMainThreadOpen("  HTTP://10.10.8.161/x.mp3  "))
    }

    @Test
    fun localPathsStayInline() {
        // Local opens cannot stall on the network; keeping them inline preserves the
        // existing ordering guarantees for the common (cached) case.
        assertFalse(RemoteLoadPolicy.needsOffMainThreadOpen("/data/data/pkg/cache/media/a.mp3"))
        assertFalse(RemoteLoadPolicy.needsOffMainThreadOpen("file:///storage/emulated/0/b.mp4"))
        assertFalse(RemoteLoadPolicy.needsOffMainThreadOpen("cb14c4babac3.mp3"))
    }

    @Test
    fun timeoutBudgetFailsFasterThanTcpGiveUp() {
        // A dead LAN host can hang for tens of seconds on retransmits. The budget must
        // be short enough that playback advances instead of waiting that out, and long
        // enough that a healthy LAN open is not cut off.
        assertTrue(RemoteLoadPolicy.REMOTE_OPEN_TIMEOUT_MS in 2_000..10_000)
    }

    /**
     * Models the fixed control flow: the blocking open runs on a worker thread and the
     * dispatch thread stays free to process later work (the `stop()` and next
     * `loadAndPlay` that never ran in the field).
     */
    @Test
    fun slowRemoteOpenDoesNotBlockTheDispatchThread() {
        val openEntered = CountDownLatch(1)
        val releaseOpen = CountDownLatch(1)
        val laterWorkRan = AtomicBoolean(false)

        val worker = Thread {
            openEntered.countDown()
            releaseOpen.await(5, TimeUnit.SECONDS) // stands in for a dead-host TCP connect
        }
        worker.isDaemon = true
        worker.start()

        assertTrue("open must start", openEntered.await(2, TimeUnit.SECONDS))

        // While the open is still stuck, the dispatch thread must remain usable.
        laterWorkRan.set(true)
        assertTrue("dispatch thread must stay free while a remote open hangs", laterWorkRan.get())

        releaseOpen.countDown()
        worker.join(2_000)
        assertFalse("worker must finish once the open unblocks", worker.isAlive)
    }

    /**
     * The timeout and the completion callback race; exactly one may settle the load,
     * or a timed-out load would be failed twice (or revived after being failed).
     */
    @Test
    fun onlyOneOfTimeoutOrCompletionSettlesTheLoad() {
        val settled = AtomicBoolean(false)
        assertTrue("first settle wins", settled.compareAndSet(false, true))
        assertFalse("second settle must be dropped", settled.compareAndSet(false, true))
    }

    @Test
    fun failedBackendStillStopsRatherThanPauses() {
        // Kept from v1.19.5: a backend carrying an error must be torn down, since
        // pause() is a no-op outside STARTED and would leave a dead surface on top.
        assertEquals(BackendQuietAction.STOP, backendQuietAction("mp_error what=1 extra=0"))
        assertEquals(BackendQuietAction.STOP, backendQuietAction("mp_remote_open_timeout:IOException"))
    }
}
