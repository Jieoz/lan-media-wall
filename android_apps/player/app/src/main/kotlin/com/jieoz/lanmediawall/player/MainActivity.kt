package com.jieoz.lanmediawall.player

import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import androidx.activity.OnBackPressedCallback
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
        // §6.1: the image layer for type=="image" playlist items. Without this
        // PlayerController.showImage() is a no-op (imageView stays null).
        ctl.attachImageView(binding.playerImage)
        playerController = ctl
        instance = this

        // Ensure the resident service is running (it drives the player + WS).
        ContextCompat.startForegroundService(
            this, Intent(this, PlayerService::class.java).apply {
                action = PlayerService.ACTION_START
            },
        )

        // Service boot can beat Activity/surface creation on Android 4.4 boxes.
        // Tell it the UI controller is now ready so reboot recovery gets a
        // second chance instead of losing resume_last in that race.
        PlayerService.instance?.onPlayerUiReady()

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
        // Lock Task 全家(startLockTask/stopLockTask/isInLockTaskMode/lockTaskModeState/
        // setLockTaskPackages)都是 API 21+。在 4.4(API 19)盒子上 dalvik 一旦解析到这些
        // 方法就抛 NoSuchMethodError(Error 非 Exception,catch(Exception) 拦不住)。4.4 本来
        // 也不该进 Lock Task,直接整体跳过 → 走软 kiosk(HOME + 吞返回 + 常驻FGS + immersive)。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
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
     * 1/6 of width × height (§debug backdoor). 7 taps within 3s → exit the kiosk.
     * Per Jay's decision the gesture is the whole gate now — no PIN prompt.
     */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            val hotW = binding.root.width / 6f
            val hotH = binding.root.height / 6f
            if (ev.x <= hotW && ev.y <= hotH) {
                if (exitGesture.onHotZoneTap(System.currentTimeMillis())) {
                    openSettings()
                }
            }
        }
        return super.dispatchTouchEvent(ev)
    }

    /**
     * D-pad backdoor for remote-only boxes: UP UP DOWN DOWN (§debug backdoor).
     * Swallow the arrow keys so they never leak to the player while matching.
     * A completed sequence exits the kiosk directly (no PIN).
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_DPAD_UP || keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
            // 上上下下 → 打开设置页(不是退出软件)。
            if (exitGesture.onKey(keyCode, System.currentTimeMillis())) {
                openSettings()
            }
            return true // consume arrows in kiosk
        }
        // §v1.13 HOME/SETUP 键:QZX_C1 等盒子的物理"回主页"键实测发的是 KEY_SETUP=
        // KEYCODE_SETTINGS(176),而不是 KEY_HOME。在播放墙上按它:消费掉(别让它弹出
        // 系统设置/漏进播放器)并把墙重新拉到前台(等价"回到播放墙")。KEY_HOME 仍由
        // MainActivity 自身的 category.HOME intent-filter(v1.13.7+)兜底——双键兜底,
        // 哪个键位都能回墙。
        if (keyCode == KeyEvent.KEYCODE_SETTINGS) {
            goToWall()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    /**
     * 回到播放墙:清掉 kiosk 挂起态并把 MainActivity(singleTask)重新拉到前台。
     * 已在前台时相当于无害的自我重排;从设置页/其它界面回来时把墙盖回最上层。
     */
    private fun goToWall() {
        KioskState.suspended = false
        try {
            startActivity(
                Intent(this, MainActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP,
                    )
                },
            )
        } catch (_: Throwable) {
            // 拉墙失败也绝不让 kiosk 崩溃退出。
        }
    }

    /**
     * 上上下下(或左上角连点7下)= **打开设置页**,不是退出软件。
     *
     * 关键:**不 finish() 本 Activity**。之前 finish 掉唯一的 kiosk Activity,在这些
     * YunOS 盒子上会让进程被系统回收,用户看到的就是"软件直接退出"而不是"进设置"。
     * 现在保留 MainActivity 在返回栈里,只是把设置页压在上面 + 挂起 kiosk 看门狗
     * (KioskState.suspended),这样进设置稳定可靠;用户在设置里按主页键即可回到播放墙
     * (MainActivity 自身即 HOME,v1.13.7+),从设置返回也会落回底下的播放 Activity 而非黑屏。
     */
    private fun openSettings() {
        KioskState.suspended = true
        // §KitKat 崩溃根因:stopLockTask() 是 API 21+ 方法,在 4.4 上 dalvik 解析该
        // 方法时抛 NoSuchMethodError —— 那是 **Error 不是 Exception**,catch(Exception)
        // 拦不住,于是 openSettings 直接 crash、进程被 Force finish,表现为"上上下下退出软件"。
        // Lock Task 本就只在 Device Owner + API 21+ 才会 startLockTask(),4.4 从没进过,
        // 所以这里必须版本守卫 + catch Throwable 双保险。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try { stopLockTask() } catch (_: Throwable) {}
        }
        try {
            startActivity(
                Intent(this, SettingsActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                },
            )
        } catch (_: Throwable) {
            // 设置页拉起失败也绝不让 kiosk 崩溃退出。
        }
        // 不 finish():播放 Activity 留在栈底,主页键/返回都能回到它。
    }

    fun showIdle() = runOnUiThread {
        binding.idleOverlay.visibility = View.VISIBLE
    }

    fun hideIdle() = runOnUiThread {
        binding.idleOverlay.visibility = View.GONE
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        playerController?.release()
        playerController = null
        super.onDestroy()
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
