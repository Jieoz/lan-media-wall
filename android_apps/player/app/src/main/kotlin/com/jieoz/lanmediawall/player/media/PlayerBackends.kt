package com.jieoz.lanmediawall.player.media

import android.content.Context
import java.io.File

/**
 * §backend-ab: Android glue that turns a [BackendSelector.Decision] into a live
 * [PlayerController]. Isolates the file/Context IO so [BackendSelector] stays a
 * pure, unit-testable policy.
 */
object PlayerBackends {

    /**
     * Test/A/B override file. The one-action A/B script (`scripts/qzx_ab_backend.sh`)
     * writes `exoplayer` / `mediaplayer` here and restarts the app; the selected
     * kernel then wins over the Settings value with NO settings-UI surgery. Lives
     * under /data/local/tmp — the same root-writable scratch dir the daemon uid
     * file uses; readable by the app, removed by the script to return to config.
     */
    const val OVERRIDE_PATH = "/data/local/tmp/lmw_video_backend"

    /** Read the override file's first non-blank token, or null if absent/blank. */
    fun readOverride(): String? = try {
        val f = File(OVERRIDE_PATH)
        if (!f.isFile) null else f.readText().trim().takeIf { it.isNotEmpty() }
    } catch (_: Throwable) {
        null
    }

    /** Resolve the backend decision from the override file + a configured value. */
    fun resolve(configured: String?): BackendSelector.Decision =
        BackendSelector.decide(readOverride(), configured)

    /** Build the concrete kernel for a decision. */
    fun createBackend(context: Context, backend: PlayerBackend): VideoBackend = when (backend) {
        PlayerBackend.EXOPLAYER -> ExoVideoBackend(context)
        PlayerBackend.MEDIAPLAYER -> MediaPlayerVideoBackend(context)
    }

    /**
     * Build a fully-wired [PlayerController] for the resolved decision. Returns the
     * controller AND the decision so the caller can log/observe WHY this kernel ran.
     */
    fun createController(context: Context, configured: String?): Pair<PlayerController, BackendSelector.Decision> {
        val decision = resolve(configured)
        val backend = createBackend(context, decision.backend)
        return PlayerController(context, backend) to decision
    }
}
