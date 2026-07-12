package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * §backend-ab: the PURE kernel-selection policy. No Android — the whole decision
 * (which kernel + WHY) is locked here so the runtime glue only has to feed it the
 * override-file contents + the persisted config value.
 *
 * Precedence under test: override file > operator config > legacy-stable auto
 * default. This is the safety contract: nothing silently flips the whole fleet to
 * the native path — AUTO stays ExoPlayer until real-device evidence justifies a
 * change (change ONE constant, [BackendSelector.AUTO_DEFAULT], and this test).
 */
class BackendSelectorTest {

    @Test
    fun auto_default_is_the_legacy_stable_exoplayer() {
        // The whole fleet's implicit default. If this ever flips, it must be a
        // deliberate, reviewed change — hence pinned here AND in the decision.
        assertEquals(PlayerBackend.EXOPLAYER, BackendSelector.AUTO_DEFAULT)
        val d = BackendSelector.decide(override = null, configured = null)
        assertEquals(PlayerBackend.EXOPLAYER, d.backend)
        assertEquals("auto-default", d.source)
    }

    @Test
    fun blank_and_auto_config_fall_through_to_auto_default() {
        for (cfg in listOf("", "   ", "auto", "AUTO", "garbage", "exo")) {
            val d = BackendSelector.decide(override = null, configured = cfg)
            assertEquals("cfg=$cfg", PlayerBackend.EXOPLAYER, d.backend)
            assertEquals("cfg=$cfg", "auto-default", d.source)
        }
    }

    @Test
    fun configured_concrete_backend_wins_over_auto() {
        val d = BackendSelector.decide(override = null, configured = "mediaplayer")
        assertEquals(PlayerBackend.MEDIAPLAYER, d.backend)
        assertEquals("config", d.source)

        val e = BackendSelector.decide(override = null, configured = "exoplayer")
        assertEquals(PlayerBackend.EXOPLAYER, e.backend)
        assertEquals("config", e.source)
    }

    @Test
    fun override_beats_configuration() {
        // The A/B script writes the override file; it must win so a test run can
        // flip the kernel without touching (or being masked by) the saved config.
        val d = BackendSelector.decide(override = "mediaplayer", configured = "exoplayer")
        assertEquals(PlayerBackend.MEDIAPLAYER, d.backend)
        assertEquals("override", d.source)

        val e = BackendSelector.decide(override = "exoplayer", configured = "mediaplayer")
        assertEquals(PlayerBackend.EXOPLAYER, e.backend)
        assertEquals("override", e.source)
    }

    @Test
    fun override_is_case_and_whitespace_tolerant() {
        val d = BackendSelector.decide(override = "  MediaPlayer\n", configured = null)
        assertEquals(PlayerBackend.MEDIAPLAYER, d.backend)
        assertEquals("override", d.source)
    }

    @Test
    fun garbage_override_falls_through_to_config_then_auto() {
        // A junk override must NOT wedge selection — it's ignored, config decides.
        val d = BackendSelector.decide(override = "banana", configured = "mediaplayer")
        assertEquals(PlayerBackend.MEDIAPLAYER, d.backend)
        assertEquals("config", d.source)
    }

    @Test
    fun decision_label_is_greppable() {
        assertEquals("mediaplayer(override)",
            BackendSelector.decide("mediaplayer", null).label())
        assertEquals("exoplayer(auto-default)",
            BackendSelector.decide(null, null).label())
    }

    @Test
    fun backend_id_round_trips() {
        assertEquals(PlayerBackend.EXOPLAYER, PlayerBackend.fromId("exoplayer"))
        assertEquals(PlayerBackend.MEDIAPLAYER, PlayerBackend.fromId("mediaplayer"))
        assertEquals(PlayerBackend.MEDIAPLAYER, PlayerBackend.fromId("MEDIAPLAYER"))
        assertNull(PlayerBackend.fromId("auto"))
        assertNull(PlayerBackend.fromId(""))
        assertNull(PlayerBackend.fromId(null))
    }
}
