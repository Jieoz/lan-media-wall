package com.jieoz.lanmediawall.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

class PlaybackModeStateTest {
    @Test fun `music is an explicit mode separate from visual playback`() {
        val state = PlaybackModeState()
        state.setMode(PlaybackMode.MUSIC)
        assertEquals(PlaybackMode.MUSIC, state.current)
        assertEquals(PlaybackMode.MUSIC, state.previousActive)
    }

    @Test fun `duplicate standby preserves music restore target`() {
        val state = PlaybackModeState()
        state.setMode(PlaybackMode.MUSIC)
        state.setMode(PlaybackMode.STANDBY)
        state.setMode(PlaybackMode.STANDBY)
        assertEquals(PlaybackMode.MUSIC, state.previousActive)
        assertEquals(PlaybackMode.MUSIC, state.restore())
    }

    @Test fun `invalid standby predecessor restores visual safely`() {
        val state = PlaybackModeState(PlaybackMode.STANDBY, PlaybackMode.STANDBY)
        assertEquals(PlaybackMode.VISUAL, state.restore())
    }
}

class ShuffleBagTest {
    @Test fun `every item plays once before reshuffle without boundary repeat`() {
        val bag = ShuffleBag<String>(Random(7))
        val items = listOf("a", "b", "c")
        val first = List(3) { bag.next(items)!! }
        val secondFirst = bag.next(items)!!
        assertEquals(items.toSet(), first.toSet())
        assertEquals(3, first.distinct().size)
        assertNotEquals(first.last(), secondFirst)
    }

    @Test fun `empty and single item playlists are safe and continuous`() {
        val bag = ShuffleBag<String>(Random(1))
        assertEquals(null, bag.next(emptyList()))
        assertTrue(List(4) { bag.next(listOf("only")) }.all { it == "only" })
    }
}
