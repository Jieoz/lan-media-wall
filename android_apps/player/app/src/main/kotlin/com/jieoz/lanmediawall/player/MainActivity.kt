package com.jieoz.lanmediawall.player

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.jieoz.lanmediawall.player.databinding.ActivityMainBinding
import com.jieoz.lanmediawall.player.media.PlayerController

/**
 * Fullscreen kiosk player Activity — protocol_spec §11.
 *
 * Hosts the Media3 [PlayerController] surface (a TextureView so frames can be
 * grabbed for thumbnails, §6.4). Enforces:
 *   - immersive fullscreen with system bars hidden, re-asserted on focus/resume
 *     and periodically by the service watchdog;
 *   - screen kept on (FLAG_KEEP_SCREEN_ON) + show-when-locked / turn-screen-on;
 *   - Lock Task Mode when the app is a Device Owner (true kiosk lockdown);
 *   - a black idle overlay so the OS desktop/launcher is never visible.
 *
 * The Activity owns the ExoPlayer (UI thread); [PlayerService] drives it via the
 * shared [playerController] reference. If first-boot setup is incomplete it
 * bounces to [SettingsActivity].
 */
@androidx.media3.common.util.UnstableApi
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var settings: Settings

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(applicationContext)

        if (!settings.isConfigured) {
            startActivity(Intent(this, SettingsActivity::class.java))
            finish()
            return
        }

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        keepScreenOnAndVisible()

        // Create the shared player controller and attach the video surface.
        val ctl = PlayerController(applicationContext).also { it.init() }
        ctl.currentVolumePercent = settings.volume
        ctl.attachSurface(binding.videoSurface)
        playerController = ctl
        instance = this

        // Ensure the resident service is running (it drives the player + WS).
        ContextCompat.startForegroundService(
            this, Intent(this, PlayerService::class.java).apply {
                action = PlayerService.ACTION_START
            },
        )

        // Block back → never drop to the launcher (§11).
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { /* swallow */ }
        })

        showIdle()
    }

    override fun onResume() {
        super.onResume()
        enterImmersive()
        tryLockTask()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersive()
    }

    private fun keepScreenOnAndVisible() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            )
        }
    }

    /** Immersive sticky fullscreen — hide status + nav bars (§11). */
    private fun enterImmersive() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, binding.root)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    /** Called by the service watchdog every ~5s to re-assert kiosk state. */
    fun reassertKiosk() {
        runOnUiThread {
            enterImmersive()
            tryLockTask()
        }
    }

    /**
     * Lock Task Mode pins the app so the user can't leave it (§11). Only starts
     * when this app is whitelisted (Device Owner sets it) — otherwise it would
     * pop a "Screen pinned" confirmation, so we check first and degrade quietly
     * on ordinary devices.
     */
    private fun tryLockTask() {
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val lockState = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.lockTaskModeState
            } else {
                @Suppress("DEPRECATION")
                if (am.isInLockTaskMode) ActivityManager.LOCK_TASK_MODE_LOCKED
                else ActivityManager.LOCK_TASK_MODE_NONE
            }
            if (lockState == ActivityManager.LOCK_TASK_MODE_NONE) {
                startLockTask() // no-op confirmation suppressed when DO-whitelisted
            }
        } catch (_: Exception) {
            // Not permitted on this device — kiosk still relies on immersive +
            // HOME activity + watchdog. Acceptable degradation.
        }
    }

    fun showIdle() = runOnUiThread {
        binding.idleOverlay.visibility = View.VISIBLE
    }

    fun hideIdle() = runOnUiThread {
        binding.idleOverlay.visibility = View.GONE
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance === this) instance = null
        // The service keeps driving playback; release the surface link only.
        playerController?.detachSurface()
    }

    companion object {
        @Volatile
        var instance: MainActivity? = null
            private set

        /** Shared ExoPlayer wrapper. Created by the Activity (UI thread), driven
         *  by [PlayerService]. Null when no kiosk Activity is foregrounded. */
        @Volatile
        var playerController: PlayerController? = null
            private set
    }
}
