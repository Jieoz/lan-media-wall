package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * §backend-ab: the pure A/B metrics accumulator. The point of the test is the
 * HONESTY contract — a kernel that cannot measure dropped frames (native
 * MediaPlayer) must render `dropped_frames=n/a`, never a fake `0`, while the
 * kernel that can (ExoPlayer) renders a real count. Counters/timers otherwise
 * accumulate identically so old-vs-native lines are directly comparable.
 */
class BackendMetricsTest {

    @Test
    fun dropped_frames_are_na_until_enabled_then_accumulate() {
        val m = BackendMetrics()
        // Native-MediaPlayer style: never enabled → must stay n/a even if the
        // (defensive) add path is called.
        m.addDroppedFrames(5)
        assertTrue(m.summary().contains("dropped_frames=n/a"))

        // ExoPlayer style: opt in, then accumulate a real number.
        val e = BackendMetrics()
        e.enableDroppedFrames()
        e.addDroppedFrames(3)
        e.addDroppedFrames(4)
        assertTrue(e.summary().contains("dropped_frames=7"))
    }

    @Test
    fun enabled_dropped_frames_start_at_zero_not_na() {
        val m = BackendMetrics()
        m.enableDroppedFrames()
        assertTrue(m.summary().contains("dropped_frames=0"))
    }

    @Test
    fun lifecycle_counts_accumulate() {
        val m = BackendMetrics()
        m.onLoad(); m.onLoad()
        m.onPrepared(120)
        m.onFirstFrame(340)
        m.onStall()
        m.onCompletion()
        m.onError("mp_error what=1 extra=-1010")
        val s = m.summary()
        assertTrue(s, s.contains("loads=2"))
        assertTrue(s, s.contains("prepared=1"))
        assertTrue(s, s.contains("first_frames=1"))
        assertTrue(s, s.contains("stalls=1"))
        assertTrue(s, s.contains("completions=1"))
        assertTrue(s, s.contains("errors=1"))
        assertTrue(s, s.contains("prepare_ms=120"))
        assertTrue(s, s.contains("first_frame_ms=340"))
        assertTrue(s, s.contains("last_error=mp_error what=1 extra=-1010"))
    }

    @Test
    fun new_item_resets_per_item_fields_but_keeps_session_counts() {
        val m = BackendMetrics()
        m.onLoad()
        m.onPrepared(100)
        m.onFirstFrame(200)
        m.onVideoSize(1920, 1080)
        m.onNewItem()
        val s = m.summary()
        // per-item latency + dims reset to sentinels...
        assertTrue(s, s.contains("prepare_ms=-1"))
        assertTrue(s, s.contains("first_frame_ms=-1"))
        assertTrue(s, s.contains("video=?"))
        // ...but cumulative session counters survive.
        assertTrue(s, s.contains("loads=1"))
    }

    @Test
    fun video_size_renders_when_known() {
        val m = BackendMetrics()
        m.onVideoSize(1280, 720)
        assertTrue(m.summary().contains("video=1280x720"))
        // a zero/garbage size must not clobber a known one.
        m.onVideoSize(0, 0)
        assertTrue(m.summary().contains("video=1280x720"))
    }

    @Test
    fun default_summary_has_no_fake_values() {
        val s = BackendMetrics().summary()
        assertTrue(s, s.contains("loads=0"))
        assertTrue(s, s.contains("prepare_ms=-1"))
        assertTrue(s, s.contains("first_frame_ms=-1"))
        assertTrue(s, s.contains("dropped_frames=n/a"))
        assertTrue(s, s.contains("video=?"))
        assertTrue(s, s.contains("last_error=none"))
    }
}
