package com.jieoz.lanmediawall.player.boot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * boot-probe: pure line-format contract for [BootAudit.formatLine]. The tail
 * parser downstream splits on '\n' and reads `key=value` tokens, so each
 * record MUST be exactly one line with the fixed key order. No Android deps.
 */
class BootAuditFormatTest {

    @Test
    fun format_is_single_line_with_fixed_key_order() {
        val line = BootAudit.formatLine(1000L, 250L, "receiver_enter", "action=BOOT sdk=29")
        assertEquals("time_ms=1000 elapsed_ms=250 event=receiver_enter detail=action=BOOT sdk=29", line)
        assertFalse("record must not contain a newline", line.contains('\n'))
    }

    @Test
    fun detail_newlines_are_flattened_so_one_record_stays_one_line() {
        val line = BootAudit.formatLine(1L, 2L, "service_start_fail", "err=Boom\nstacktrace\r\nmore")
        assertEquals(1, line.count { it == '\n' } + 1) // no embedded newlines -> stays a single record
        assertFalse(line.contains('\n'))
        assertFalse(line.contains('\r'))
        assertTrue(line.startsWith("time_ms=1 elapsed_ms=2 event=service_start_fail detail=err=Boom"))
    }

    @Test
    fun empty_detail_is_preserved() {
        val line = BootAudit.formatLine(42L, 7L, "receiver_exit", "")
        assertEquals("time_ms=42 elapsed_ms=7 event=receiver_exit detail=", line)
    }
}
