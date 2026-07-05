package com.jieoz.lanmediawall.player

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.jieoz.lanmediawall.player.databinding.ActivitySettingsBinding
import com.jieoz.lanmediawall.player.net.DiscoveryDecision
import com.jieoz.lanmediawall.player.pair.QrEncoder
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * First-boot setup — protocol_spec §4 / redesign §2, §4.2: custom device_name
 * (persisted), broker address, PSK, group, thumbnail policy. Re-openable later
 * for reconfiguration.
 *
 * §7 (LAN-only downgrade): the PSK and all secrets live in plain
 * SharedPreferences (see [Settings]) — EncryptedSharedPreferences needs API 23+
 * and can't run on the 4.4 target. Everything else in the same plain store.
 *
 * §1 configuration reversal: this camera-less TV box does NOT scan. It DISPLAYS
 * its own enrollment QR (built by [QrEncoder]) plus its LAN IP / device_id /
 * group, so the phone controller scans it — the operator types nothing here.
 *
 * §4.1 mode 2: a "set as home" toggle flips the default-disabled HOME
 * [activity-alias] on/off at runtime via [PackageManager.setComponentEnabledSetting].
 *
 * On save we mark the device configured, (re)start the service, and launch the
 * kiosk player.
 */
class SettingsActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySettingsBinding
    private lateinit var settings: Settings

    /** §2 connection-status refresher: ConnState is polled by the service, so
     *  re-render it on a light UI-thread tick while this screen is visible. */
    private val ui = Handler(Looper.getMainLooper())
    private val connTick = object : Runnable {
        override fun run() {
            renderConnStatus()
            ui.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(applicationContext)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        prefillFromSettings()
        showDeviceInfoAndQr()
        showHardwareSelfCheck()
        showBloatware()

        // HomeAlias 现在 manifest 默认启用(v1.10.3+),所以首次进设置也应勾上;
        // 保留读取当前实际状态,便于用户主动关掉(极少数不想抢 HOME 的场景)。
        binding.inputSetAsHome.isChecked = isHomeAliasEnabled()
        binding.btnSave.setOnClickListener { save() }
        binding.btnResetConn.setOnClickListener { confirmResetConnection() }
    }

    override fun onResume() {
        super.onResume()
        ui.post(connTick) // start/refresh the connection-status ticker
    }

    override fun onPause() {
        super.onPause()
        ui.removeCallbacks(connTick)
    }

    /** Fill every input from the current [settings] (used on open). */
    private fun prefillFromSettings() {
        // device_name defaults to device_id; leave blank until configured.
        binding.inputDeviceName.setText(
            if (settings.isConfigured) settings.deviceName else "",
        )
        binding.inputBrokerHost.setText(settings.brokerHost)
        binding.inputBrokerPort.setText(settings.brokerPort.toString())
        binding.inputUseWss.isChecked = settings.useWss
        binding.inputGroupId.setText(settings.groupId)
        // §13/§15.3 open semantics: DEFAULT_PSK means "no key" → show empty.
        binding.inputPsk.setText(if (settings.psk == Settings.DEFAULT_PSK) "" else settings.psk)
        binding.inputAlwaysThumbs.isChecked = settings.alwaysCollectThumbnails
    }

    /**
     * §2/§1: show this box's LAN IP + device_id + group, and render the
     * enrollment QR the phone controller scans. The QR points the phone at THIS
     * device as an open-mode p2p coordinator (host=<lan-ip> port=<p2p>), so no
     * one types the connection details.
     */
    private fun showDeviceInfoAndQr() {
        val ip = detectIp()
        // 版本号来自 BuildConfig(单一真相源:gradle versionName/Code),永不漂移。
        binding.textDeviceInfo.text = getString(
            R.string.device_info_fmt, ip, settings.deviceId, settings.groupId,
            BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE,
        )
        val uri = QrEncoder.buildEnrollUri(
            ip = ip,
            port = DiscoveryDecision.P2P_PORT,
            group = settings.groupId,
            deviceId = settings.deviceId,
            deviceName = if (settings.isConfigured) settings.deviceName else settings.deviceId,
        )
        binding.textPairUri.text = uri
        val bmp = QrEncoder.encodeBitmap(uri, sizePx = 512)
        if (bmp != null) {
            binding.imagePairQr.setImageBitmap(bmp)
        }
    }

    /**
     * §2 hardware self-check: real MemTotal (from /proc/meminfo) + /data free /
     * total capacity (StatFs). Lets an operator judge from a screenshot whether
     * the box hardware is good enough. Pure display — never blocks setup.
     */
    private fun showHardwareSelfCheck() {
        val unknown = getString(R.string.hw_unknown)
        val mem = SystemInfo.memTotalMb()?.let { mb(it) } ?: unknown
        val free = SystemInfo.dataFreeMb()?.let { mb(it) } ?: unknown
        val total = SystemInfo.dataTotalMb()?.let { mb(it) } ?: unknown
        val memLine = getString(R.string.hw_mem_fmt, mem)
        val storageLine = getString(R.string.hw_storage_fmt, free, total)
        binding.textHardware.text = "$memLine\n$storageLine"
    }

    private fun mb(value: Long): String = getString(R.string.hw_mb_fmt, value)

    /**
     * §junk: flag known PCDN-miner / background-daemon packages preinstalled on
     * these boxes. Visible warning + manual-disable advice only — we never
     * uninstall or kill (4.4 permissions + risk). Empty → a reassuring "none".
     */
    private fun showBloatware() {
        val found = SystemInfo.scanBloatware(applicationContext)
        binding.textBloatware.text = if (found.isEmpty()) {
            getString(R.string.bloatware_none)
        } else {
            val lines = found.joinToString("\n") { "• ${it.label}\n  ${it.pkg}" }
            "${getString(R.string.bloatware_advice)}\n$lines"
        }
    }

    /** §2: render the live [ConnState] phase into the status line. */
    private fun renderConnStatus() {
        val d = ConnState.detail
        val text = when (ConnState.phase) {
            ConnState.Phase.STARTING -> getString(R.string.conn_starting)
            ConnState.Phase.DISCOVERING -> getString(R.string.conn_discovering)
            ConnState.Phase.CONNECTING_BROKER ->
                getString(R.string.conn_connecting_broker_fmt, d)
            ConnState.Phase.CONNECTED_BROKER ->
                getString(R.string.conn_connected_broker_fmt, d)
            ConnState.Phase.P2P_WAITING ->
                getString(R.string.conn_p2p_waiting_fmt, d)
            ConnState.Phase.P2P_CONNECTED -> getString(R.string.conn_p2p_connected)
            ConnState.Phase.DISCONNECTED ->
                if (d.isNotEmpty()) getString(R.string.conn_disconnected_fmt, d)
                else getString(R.string.conn_disconnected)
        }
        binding.textConnStatus.text = text
    }

    /**
     * §9 self-recovery: confirm, then wipe the connection config and bounce back
     * to a clean first-boot setup (unconfigured → auto-discover / QR pairing).
     * Restarts the service so it re-selects a transport under the reset state.
     */
    private fun confirmResetConnection() {
        AlertDialog.Builder(this)
            .setTitle(R.string.reset_conn_confirm_title)
            .setMessage(R.string.reset_conn_confirm_msg)
            .setNegativeButton(R.string.action_cancel, null)
            .setPositiveButton(R.string.action_confirm) { _, _ -> doResetConnection() }
            .show()
    }

    private fun doResetConnection() {
        settings.resetConnection()
        // re-render everything so the UI reflects the cleared state immediately.
        prefillFromSettings()
        showDeviceInfoAndQr()
        ConnState.set(ConnState.Phase.STARTING)
        // restart the service so the transport is re-selected under the reset
        // (now broker-less → auto-discover / p2p) state.
        val svc = Intent(this, PlayerService::class.java).apply {
            action = PlayerService.ACTION_START
        }
        ContextCompat.startForegroundService(this, svc)
        toast(getString(R.string.reset_conn_done))
    }

    private fun save() {
        val name = binding.inputDeviceName.text.toString().trim()
        val host = binding.inputBrokerHost.text.toString().trim()
        val portText = binding.inputBrokerPort.text.toString().trim()
        val groupId = binding.inputGroupId.text.toString().trim()
        val psk = binding.inputPsk.text.toString()

        // §2 zero-config: broker host is OPTIONAL now. Empty → keep the default
        // and let discovery/p2p-fallback find (or become) the coordinator.
        val port = if (portText.isEmpty()) settings.brokerPort else portText.toIntOrNull()
        if (port == null || port !in 1..65535) {
            toast(getString(R.string.err_broker_port)); return
        }
        // §13/§15.3: PSK is OPTIONAL. v1.1+ defaults to `open` (zero-config, no
        // key). An empty field means "no key" — the player connects to an open
        // broker and signs sig="" (see Envelope.hasUsableKey / AuthMode.OPEN).
        // Only a non-empty PSK enables optional/required signing.

        settings.deviceName = if (name.isEmpty()) settings.deviceId else name
        // §2 zero-config: always persist the host, INCLUDING empty. An empty
        // broker means "no broker" → the transport layer auto-discovers / falls
        // back to the p2p server (§14.3). Writing it unconditionally is what lets
        // an operator *clear* a bad broker and return to auto-discovery, and
        // stops a blank field from silently keeping a stale/phantom host.
        settings.brokerHost = host
        settings.brokerPort = port
        settings.useWss = binding.inputUseWss.isChecked
        settings.groupId = if (groupId.isEmpty()) "default" else groupId
        settings.psk = psk
        settings.alwaysCollectThumbnails = binding.inputAlwaysThumbs.isChecked
        settings.markConfigured()

        // §4.1 mode 2: apply the "set as home" toggle (default-disabled alias).
        setHomeAliasEnabled(binding.inputSetAsHome.isChecked)

        // Restart the service so it picks up the new connection settings.
        val svc = Intent(this, PlayerService::class.java).apply {
            action = PlayerService.ACTION_START
        }
        ContextCompat.startForegroundService(this, svc)

        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }

    // --- §4.1 mode 2: HOME activity-alias runtime toggle -----------------

    private fun homeAlias() = ComponentName(this, HOME_ALIAS)

    private fun isHomeAliasEnabled(): Boolean =
        packageManager.getComponentEnabledSetting(homeAlias()) ==
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED

    /**
     * Flip the HOME [activity-alias] on/off. `setComponentEnabledSetting` is
     * available since API 1 (works on 4.4). DONT_KILL_APP so we aren't
     * terminated mid-settings. Enabling makes this box a HOME candidate; the
     * user still picks it as default launcher once from the system chooser.
     */
    private fun setHomeAliasEnabled(enabled: Boolean) {
        val state = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        try {
            packageManager.setComponentEnabledSetting(
                homeAlias(), state, PackageManager.DONT_KILL_APP,
            )
        } catch (_: Exception) {
            // Some ROMs restrict alias toggling; soft kiosk still applies.
        }
    }

    private fun detectIp(): String {
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return "0.0.0.0"
            for (iface in ifaces) {
                if (!iface.isUp || iface.isLoopback) continue
                for (addr in iface.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress) {
                        return addr.hostAddress ?: continue
                    }
                }
            }
        } catch (_: Exception) {
        }
        return "0.0.0.0"
    }

    private fun toast(msg: String) =
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    companion object {
        /** Fully-qualified name of the default-disabled HOME alias (§4.1). */
        private const val HOME_ALIAS = "com.jieoz.lanmediawall.player.HomeAlias"
    }
}
