package com.jieoz.lanmediawall.player.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * §backend-ab: the PURE kernel-selection policy. No Android — the whole decision
 * (which kernel + WHY) is locked here so the runtime glue only has to feed it the
 * override-file contents + the persisted config value.
 *
 * Precedence under test: override file > operator config > auto default. This is
 * the safety contract: the fleet default lives in exactly ONE constant,
 * [BackendSelector.AUTO_DEFAULT], with no device-name branch. Real QZX_C1 A/B
 * evidence moved AUTO to MediaPlayer (ExoPlayer visibly dropped frames); flipping
 * it back is a deliberate, reviewed change to that one constant and this test.
 */
class BackendSelectorTest {

    @Test
    fun auto_default_is_the_qzx_validated_mediaplayer() {
        // The whole fleet's implicit default. If this ever flips, it must be a
        // deliberate, reviewed change — hence pinned here AND in the decision.
        assertEquals(PlayerBackend.MEDIAPLAYER, BackendSelector.AUTO_DEFAULT)
        val d = BackendSelector.decide(override = null, configured = null)
        assertEquals(PlayerBackend.MEDIAPLAYER, d.backend)
        assertEquals("auto-default", d.source)
    }

    @Test
    fun blank_and_auto_config_fall_through_to_auto_default() {
        for (cfg in listOf("", "   ", "auto", "AUTO", "garbage", "exo")) {
            val d = BackendSelector.decide(override = null, configured = cfg)
            assertEquals("cfg=$cfg", PlayerBackend.MEDIAPLAYER, d.backend)
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
        assertEquals("mediaplayer(auto-default)",
            BackendSelector.decide(null, null).label())
    }

    /**
     * Regression for the v1.14.7 field bug: Settings claimed MediaPlayer while
     * playback stayed on ExoPlayer. Root cause was the running Activity/controller
     * never being rebuilt — but the persisted-value → kernel mapping is the other
     * half of the contract and is pinned here. These are the EXACT three strings
     * `SettingsActivity.save()` writes into `settings.videoBackend`:
     *   - the "auto" sentinel (Settings.VIDEO_BACKEND_AUTO)
     *   - PlayerBackend.EXOPLAYER.id
     *   - PlayerBackend.MEDIAPLAYER.id
     * Whatever the Activity persists must deterministically resolve to the kernel
     * the operator picked, with AUTO landing on the QZX-validated MediaPlayer.
     */
    @Test
    fun persisted_settings_value_resolves_to_the_picked_kernel() {
        // "auto" sentinel → QZX-validated default.
        val auto = BackendSelector.decide(override = null, configured = "auto")
        assertEquals(PlayerBackend.MEDIAPLAYER, auto.backend)
        assertEquals("auto-default", auto.source)

        // Explicit MediaPlayer choice.
        val mp = BackendSelector.decide(override = null, configured = PlayerBackend.MEDIAPLAYER.id)
        assertEquals(PlayerBackend.MEDIAPLAYER, mp.backend)
        assertEquals("config", mp.source)

        // Explicit ExoPlayer operator override stays available.
        val exo = BackendSelector.decide(override = null, configured = PlayerBackend.EXOPLAYER.id)
        assertEquals(PlayerBackend.EXOPLAYER, exo.backend)
        assertEquals("config", exo.source)
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
