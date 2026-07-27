package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Regression guards for the v1.19.4 field black screen: 音乐 → 图片 left a failed
 * MediaPlayer covering the image because `pause()` does nothing outside STARTED.
 */
class FailedBackendPolicyTest {

    @Test
    fun healthyBackendIsPaused() {
        assertEquals(BackendQuietAction.PAUSE, backendQuietAction(null))
    }

    @Test
    fun failedBackendIsStoppedNotPaused() {
        // Exactly the code observed in the field log on and-c937df0cdb.
        assertEquals(BackendQuietAction.STOP, backendQuietAction("mp_error what=1 extra=0"))
    }

    @Test
    fun loadStageFailuresAlsoStop() {
        assertEquals(BackendQuietAction.STOP, backendQuietAction("mp_setDataSource:IOException"))
        assertEquals(BackendQuietAction.STOP, backendQuietAction("mp_prepareAsync:IllegalStateException"))
    }

    @Test
    fun blankErrorIsTreatedAsHealthy() {
        // Defensive: a kernel reporting "" must not trigger a needless teardown,
        // which would drop a perfectly good paused instance on every image.
        assertEquals(BackendQuietAction.PAUSE, backendQuietAction(""))
        assertEquals(BackendQuietAction.PAUSE, backendQuietAction("   "))
    }
}
