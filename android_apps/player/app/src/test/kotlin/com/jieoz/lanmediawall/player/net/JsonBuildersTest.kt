package com.jieoz.lanmediawall.player.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class JsonBuildersTest {
    @Test
    fun integerAccessorsRejectFractionsAndOverflow() {
        assertNull(Json.Num("8770.5").asIntOrNull())
        assertNull(Json.Num("2147483648").asIntOrNull())
        assertNull(Json.Num("9223372036854775808").asLongOrNull())
    }

    @Test
    fun integerAccessorsAcceptExactInRangeValues() {
        assertEquals(8770, Json.Num("8770").asIntOrNull())
        assertEquals(120000L, Json.Num("120000").asLongOrNull())
    }
}
