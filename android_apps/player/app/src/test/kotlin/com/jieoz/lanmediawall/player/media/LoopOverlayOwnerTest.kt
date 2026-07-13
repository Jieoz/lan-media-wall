package com.jieoz.lanmediawall.player.media

import org.junit.Assert.*
import org.junit.Test

class LoopOverlayOwnerTest {
    @Test fun replacementRejectsOldCallback() {
        val owner = LoopOverlayOwner()
        val old = owner.arm("old")!!
        val replacement = owner.arm("new")!!
        assertFalse(owner.accepts(old))
        assertTrue(owner.accepts(replacement))
        owner.disarm()
        assertFalse(owner.accepts(replacement))
    }
}