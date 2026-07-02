package com.jieoz.lanmediawall.player

import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.EditText
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.jieoz.lanmediawall.player.admin.PlayerDeviceAdminReceiver
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
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var settings: Settings

    /** Hidden kiosk-exit backdoor matcher (top-left taps + D-pad sequence). */
    private val exitGesture = ExitGestureDetector()
    @Volatile private var pinDialogShowing = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(applicationContext)

        // Fresh entry into the kiosk Activity re-arms the lockdown: any prior
        // debug-backdoor suspension is cleared so the wall locks itself back
        // down (§11). The backdoor is only ever a temporary switch.
        KioskState.suspended = false

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
        // While the debug backdoor is engaged, don't re-grab the screen — let
        // the operator reach Settings / desktop.
        if (KioskState.suspended) return
        enterImmersive()
        tryLockTask()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !KioskState.suspended) enterImmersive()
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
        if (KioskState.suspended) return // backdoor engaged — stay out of the way
        runOnUiThread {
            if (KioskState.suspended) return@runOnUiThread
            enterImmersive()
            tryLockTask()
        }
    }

    /**
     * Lock Task Mode pins the app so the user can't leave it (§11). Gated on
     * being a **Device Owner**: only then does startLockTask() engage silently
     * (with an explicit self-whitelist). On an ordinary/un-provisioned box we do
     * NOT call startLockTask() at all — that would repeatedly pop the system
     * "Screen pinned" confirmation (the old痛点). There we degrade to the soft
     * kiosk (HOME launcher + swallowed back + resident FGS + immersive watchdog),
     * which is already in force. See README §device-owner.
     */
    private fun tryLockTask() {
        if (KioskState.suspended) return
        try {
            val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val isDeviceOwner = dpm.isDeviceOwnerApp(packageName)

            if (!isDeviceOwner) {
                // Soft kiosk only — never prompt. (isLockTaskPermitted is false
                // for a non-owner without a DO-set whitelist anyway.)
                return
            }

            // Device Owner: whitelist ourselves so Lock Task is silent, then lock.
            try {
                dpm.setLockTaskPackages(
                    ComponentName(this, PlayerDeviceAdminReceiver::class.java),
                    arrayOf(packageName),
                )
            } catch (_: Exception) {
                // setLockTaskPackages requires DO; ignore if it races.
            }

            val lockState = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.lockTaskModeState
            } else {
                @Suppress("DEPRECATION")
                if (am.isInLockTaskMode) ActivityManager.LOCK_TASK_MODE_LOCKED
                else ActivityManager.LOCK_TASK_MODE_NONE
            }
            if (lockState == ActivityManager.LOCK_TASK_MODE_NONE) {
                startLockTask() // silent: we're DO-whitelisted
            }
        } catch (_: Exception) {
            // Not permitted on this device — kiosk still relies on immersive +
            // HOME activity + watchdog. Acceptable degradation.
        }
    }

    // --- hidden kiosk-exit backdoor (on-device debugging) ----------------

    /**
     * Catch every touch before children consume it so the top-left hot-zone tap
     * counter works even over the video surface. The hot-zone is the top-left
     * 1/6 of width × height (§debug backdoor). 7 taps within 3s → PIN prompt.
     */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN && !pinDialogShowing) {
            val hotW = binding.root.width / 6f
            val hotH = binding.root.height / 6f
            if (ev.x <= hotW && ev.y <= hotH) {
                if (exitGesture.onHotZoneTap(System.currentTimeMillis())) {
                    promptExitPin()
                }
            }
        }
        return super.dispatchTouchEvent(ev)
    }

    /**
     * D-pad backdoor for remote-only boxes: UP UP DOWN DOWN (§debug backdoor).
     * Swallow the arrow keys so they never leak to the player while matching.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_DPAD_UP || keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
            if (!pinDialogShowing && exitGesture.onKey(keyCode, System.currentTimeMillis())) {
                promptExitPin()
            }
            return true // consume arrows in kiosk
        }
        return super.onKeyDown(keyCode, event)
    }

    /** Show the PIN dialog; correct PIN → [exitKiosk], wrong → toast, no exit. */
    private fun promptExitPin() {
        if (pinDialogShowing) return
        pinDialogShowing = true
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
            hint = getString(R.string.kiosk_pin_hint)
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.kiosk_pin_title)
            .setView(input)
            .setCancelable(true)
            .setPositiveButton(R.string.kiosk_pin_ok) { _, _ ->
                if (input.text.toString() == settings.kioskExitPin) {
                    exitKiosk()
                } else {
                    Toast.makeText(this, R.string.kiosk_pin_wrong, Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton(R.string.kiosk_pin_cancel, null)
            .setOnDismissListener { pinDialogShowing = false }
            .show()
    }

    /**
     * Release the kiosk locally for debugging: stop Lock Task, set the runtime
     * [KioskState.suspended] gate (so the service watchdog stops re-locking /
     * re-immersing), then jump to Settings and finish this Activity so a system
     * Back from Settings reaches the desktop instead of re-pinning us.
     */
    private fun exitKiosk() {
        KioskState.suspended = true
        try { stopLockTask() } catch (_: Exception) {}
        try {
            val ctl = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            // (no-op read; kept for symmetry/logging hooks)
            ctl.lockTaskModeState
        } catch (_: Exception) {}
        startActivity(Intent(this, SettingsActivity::class.java))
        finish()
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
