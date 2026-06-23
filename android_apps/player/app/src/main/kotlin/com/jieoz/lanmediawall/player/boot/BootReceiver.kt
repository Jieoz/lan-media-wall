package com.jieoz.lanmediawall.player.boot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.ContextCompat
import com.jieoz.lanmediawall.player.MainActivity
import com.jieoz.lanmediawall.player.PlayerService

/**
 * Open on boot — protocol_spec §11. On BOOT_COMPLETED (and OEM quick-boot
 * variants) we start the resident [PlayerService] and bring the kiosk
 * [MainActivity] to the front, so the wall comes back up unattended after a
 * power cycle without anyone touching the device.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action !in BOOT_ACTIONS) return

        // Start the foreground service (it owns WS + watchdog + resume_last).
        val serviceIntent = Intent(context, PlayerService::class.java).apply {
            this.action = PlayerService.ACTION_START
        }
        ContextCompat.startForegroundService(context, serviceIntent)

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
        private val BOOT_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.LOCKED_BOOT_COMPLETED",
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
    }
}
