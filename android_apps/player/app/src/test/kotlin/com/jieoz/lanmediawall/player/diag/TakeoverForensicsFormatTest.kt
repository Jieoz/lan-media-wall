package com.jieoz.lanmediawall.player.diag

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * field-fix+71: pure-format contract for [TakeoverForensics]. The exported
 * `takeover_forensics` block is parsed by eye (and possibly by a downstream
 * key=value scraper), so the line shapes and the list-capping behaviour must be
 * stable and Android-free.
 */
class TakeoverForensicsFormatTest {

    @Test
    fun capList_returns_input_untouched_when_within_limit() {
        val input = listOf("a", "b", "c")
        assertEquals(input, TakeoverForensics.capList(input, 3))
        assertEquals(input, TakeoverForensics.capList(input, 5))
    }

    @Test
    fun capList_truncates_and_appends_a_single_more_marker() {
        val input = (1..10).map { "line$it" }
        val out = TakeoverForensics.capList(input, 4)
        assertEquals(5, out.size) // 4 kept + 1 marker
        assertEquals("line1", out.first())
        assertEquals("line4", out[3])
        assertEquals("... (+6 more, truncated)", out.last())
    }

    @Test
    fun capList_at_exact_limit_does_not_add_marker() {
        val input = (1..4).map { "line$it" }
        val out = TakeoverForensics.capList(input, 4)
        assertEquals(4, out.size)
        assertFalse(out.any { it.contains("truncated") })
    }

    @Test
    fun looksInteresting_matches_tokens_in_package_or_label_case_insensitively() {
        assertTrue(TakeoverForensics.looksInteresting("com.oem.LAUNCHER", null))
        assertTrue(TakeoverForensics.looksInteresting("com.acme.app", "Super TV Player"))
        assertTrue(TakeoverForensics.looksInteresting("com.youku.tv", null))
        assertFalse(TakeoverForensics.looksInteresting("com.example.calculator", "Calc"))
    }

    @Test
    fun joinIds_is_stable_comma_join() {
        assertEquals("a,b,c", TakeoverForensics.joinIds(listOf("a", "b", "c")))
        assertEquals("", TakeoverForensics.joinIds(emptyList()))
    }

    @Test
    fun homeCandidateLine_has_fixed_shape_and_no_newline() {
        val line = TakeoverForensics.homeCandidateLine(
            pkg = "com.oem.home",
            cls = "com.oem.home.HomeActivity",
            priority = 5,
            isDefault = true,
            isMine = false,
        )
        assertEquals(
            "home_candidate pkg=com.oem.home cls=com.oem.home.HomeActivity " +
                "priority=5 default=true mine=false",
            line,
        )
        assertFalse(line.contains('\n'))
    }

    @Test
    fun packageLine_renders_unknown_version_as_question_mark() {
        val line = TakeoverForensics.packageLine(
            pkg = "com.oem.player",
            versionName = null,
            enabled = true,
            systemApp = true,
            hasHome = false,
            hasLeanback = true,
            heuristic = true,
        )
        assertEquals(
            "pkg=com.oem.player version=? enabled=true system=true " +
                "home=false leanback=true heuristic=true",
            line,
        )
    }
}
