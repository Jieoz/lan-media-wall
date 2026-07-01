package com.jieoz.lanmediawall.player

/**
 * Runtime kiosk lockdown state shared between [MainActivity] (which enforces
 * Lock Task + immersive) and [PlayerService] (whose watchdog re-asserts them).
 *
 * [suspended] is the §debug-backdoor gate (see [ExitGestureDetector]): while
 * true, the watchdog must NOT re-lock / re-immerse and Lock Task stays released,
 * so an operator who entered the PIN can actually reach Settings / the desktop
 * for on-device debugging. It is **process-static on purpose**:
 *   - a reboot (process death) resets it to false → the wall locks itself back
 *     down unattended (§11), so the backdoor is only ever a temporary switch;
 *   - re-entering the kiosk Activity also resets it (MainActivity.onCreate),
 *     so returning to the player re-arms the lockdown.
 */
object KioskState {
    @Volatile
    var suspended: Boolean = false
}
