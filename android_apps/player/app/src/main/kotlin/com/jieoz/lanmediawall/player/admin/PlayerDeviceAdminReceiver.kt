package com.jieoz.lanmediawall.player.admin

import android.app.admin.DeviceAdminReceiver

/**
 * Device Admin receiver — the hook that lets a provisioned box make this app a
 * **Device Owner** so Lock Task Mode engages silently (true kiosk, §11) instead
 * of popping the system "Screen pinned" confirmation.
 *
 * This class does nothing on its own; being *declared* (with the paired
 * `res/xml/device_admin.xml` policy + manifest `<receiver>`) is what lets an
 * operator run, on an un-provisioned/factory-fresh box (no Google account
 * added):
 *
 *     adb shell dpm set-device-owner \
 *       com.jieoz.lanmediawall.player/.admin.PlayerDeviceAdminReceiver
 *
 * Once it is Device Owner, [com.jieoz.lanmediawall.player.MainActivity] detects
 * that (DevicePolicyManager.isDeviceOwnerApp) and whitelists itself +
 * startLockTask() with no prompt. On boxes that can't be provisioned (rooted-
 * only, MDM-managed, or with accounts) this stays inert and the app degrades to
 * the soft-kiosk path. See README §device-owner.
 */
class PlayerDeviceAdminReceiver : DeviceAdminReceiver()
