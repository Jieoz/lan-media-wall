package com.jieoz.lanmediawall.player.boot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.jieoz.lanmediawall.player.MainActivity
import com.jieoz.lanmediawall.player.PlayerService

/**
 * Open on boot — protocol_spec §11 / redesign §4. On BOOT_COMPLETED (and OEM
 * quick-boot variants) we start the resident [PlayerService] and bring the kiosk
 * [MainActivity] to the front, so the wall comes back up unattended after a
 * power cycle without anyone touching the device.
 *
 * §4/§6.1: `startForegroundService` is API 26+ only — calling it blindly crashed
 * boot on the 4.4 target. We branch on [Build.VERSION.SDK_INT]: <26 uses the
 * plain `startService`. A [Log] line (tag [TAG]) lets ops verify self-start with
 * `adb logcat | grep BootReceiver` after `adb reboot` (§4.2).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action !in BOOT_ACTIONS) return
        Log.i(TAG, "boot self-start on $action (sdk=${Build.VERSION.SDK_INT})")

        // Start the resident service (it owns WS + watchdog + resume_last).
        // §4/§6.1: startForegroundService is 26+; <26 must use startService.
        val serviceIntent = Intent(context, PlayerService::class.java).apply {
            this.action = PlayerService.ACTION_START
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }

        // Bring the kiosk activity forward so the screen is the player, never
        // the launcher. NEW_TASK is required from a receiver context.
        val activityIntent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        try {
            context.startActivity(activityIntent)
        } catch (e: Exception) {
            // Some OEMs block background activity starts; the service + its
            // full-screen notification still recover the player.
        }
    }

    companion object {
        private const val TAG = "BootReceiver"

        private val BOOT_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.LOCKED_BOOT_COMPLETED",
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
    }
}
