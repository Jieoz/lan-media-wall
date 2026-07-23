package com.jieoz.lanmediawall.player.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CoordinatorLinkDeliveryTest {
    private class FakeLink(private val result: String?) : CoordinatorLink {
        override val isConnected: Boolean = result != null
        override val authMode: AuthMode = AuthMode.OPTIONAL
        override fun start() = Unit
        override fun stop() = Unit
        override fun send(type: String, payload: Json, to: String): String? = result
        override fun sendBinary(data: ByteArray): Boolean = false
    }

    @Test
    fun requiredSendReturnsMessageIdWhenFrameWasAccepted() {
        assertEquals("msg-1", FakeLink("msg-1").sendRequired("status", Json.Obj(emptyMap())))
    }

    @Test
    fun requiredSendThrowsWhenTransportRejectedFrame() {
        assertThrows(IllegalStateException::class.java) {
            FakeLink(null).sendRequired("status", Json.Obj(emptyMap()))
        }
    }
}
