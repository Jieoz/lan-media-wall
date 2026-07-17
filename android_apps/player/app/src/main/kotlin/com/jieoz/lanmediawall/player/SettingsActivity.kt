package com.jieoz.lanmediawall.player

import android.content.Intent
import android.os.Build
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
import java.io.File


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
 * §4.1: the kiosk player IS the box's HOME/launcher — the HOME intent-filter
 * lives directly on [MainActivity] (v1.13.7+), so there is no runtime toggle.
 *
 * On save we mark the device configured, (re)start the service, and launch the
 * kiosk player.
 */
class SettingsActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySettingsBinding
    private lateinit var settings: Settings
    /** Last service availability represented by the diagnostics labels. */
    private var diagnosticsServicePresent = false

    /** §2 connection-status refresher: ConnState is polled by the service, so
     *  re-render it on a light UI-thread tick while this screen is visible. */
    private val ui = Handler(Looper.getMainLooper())
    private val connTick = object : Runnable {
        override fun run() {
            detectStalledServiceStart()
            renderConnStatus()
            val servicePresent = PlayerService.instance != null
            if (DiagnosticsRefreshPolicy.shouldRefresh(diagnosticsServicePresent, servicePresent)) {
                renderDiagnostics()
            }
            ui.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(applicationContext)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        prefillFromSettings()
        val startupPhase = StartupStatusPolicy.phaseFor(
            configured = settings.isConfigured,
            servicePresent = PlayerService.instance != null,
            current = ConnState.phase,
            startRequestedElapsedMs = serviceStartElapsedMs,
            nowElapsedMs = android.os.SystemClock.elapsedRealtime(),
        )
        if (startupPhase != ConnState.phase) ConnState.set(startupPhase)
        showDeviceInfoAndQr()
        showHardwareSelfCheck()
        showBloatware()
        renderDiagnostics()

        binding.btnSave.setOnClickListener { save() }
        binding.btnResetConn.setOnClickListener { confirmResetConnection() }
        binding.btnRefreshDiag.setOnClickListener { renderDiagnostics() }
        binding.btnRestartService.setOnClickListener { startPlayerService() }
        binding.btnExportDiag.setOnClickListener { chooseDiagnosticExportPath() }
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
        // §backend-ab: reflect the persisted video-kernel choice.
        val checkedId = when (com.jieoz.lanmediawall.player.media.PlayerBackend.fromId(settings.videoBackend)) {
            com.jieoz.lanmediawall.player.media.PlayerBackend.EXOPLAYER -> R.id.backend_exoplayer
            com.jieoz.lanmediawall.player.media.PlayerBackend.MEDIAPLAYER -> R.id.backend_mediaplayer
            else -> R.id.backend_auto // auto/blank/unknown
        }
        binding.groupVideoBackend.check(checkedId)
    }

    /**
     * §2/§1: show this box's LAN IP + device_id + group, and render the
     * enrollment QR the phone controller scans. The QR points the phone at THIS
     * device as an open-mode p2p coordinator (host=<lan-ip> port=<p2p>), so no
     * one types the connection details.
     */
    private fun showDeviceInfoAndQr() {
        val ip = AndroidNet.detectLanIp()
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
            ConnState.Phase.WAITING_SETUP -> getString(R.string.conn_waiting_setup)
            ConnState.Phase.STARTING -> getString(R.string.conn_starting)
            ConnState.Phase.START_FAILED -> getString(
                R.string.conn_start_failed_fmt,
                d.ifBlank { getString(R.string.conn_unknown_failure) },
            )
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

    /** Turn a forever-STARTING OEM failure into an actionable on-screen state. */
    private fun detectStalledServiceStart() {
        if (ConnState.phase != ConnState.Phase.STARTING || PlayerService.instance != null) return
        val age = android.os.SystemClock.elapsedRealtime() - serviceStartElapsedMs
        if (serviceStartElapsedMs > 0L && age >= StartupStatusPolicy.SERVICE_START_TIMEOUT_MS) {
            ConnState.set(ConnState.Phase.START_FAILED, getString(R.string.conn_service_not_created))
        }
    }

    /** Start/restart with Throwable capture so TVs without ADB display the cause. */
    private fun startPlayerService() {
        ConnState.set(ConnState.Phase.STARTING, getString(R.string.conn_requesting_service))
        serviceStartElapsedMs = android.os.SystemClock.elapsedRealtime()
        val svc = Intent(this, PlayerService::class.java).apply {
            action = PlayerService.ACTION_START
        }
        try {
            ContextCompat.startForegroundService(this, svc)
            toast(getString(R.string.service_restart_requested))
        } catch (t: Throwable) {
            ConnState.set(
                ConnState.Phase.START_FAILED,
                "${t.javaClass.simpleName}: ${t.message ?: getString(R.string.conn_unknown_failure)}",
            )
            renderConnStatus()
            renderDiagnostics()
        }
    }

    /**
     * §2 no-ADB export: ask Android's document provider for the destination.
     * This lets the operator pick internal storage, Downloads, or a mounted USB
     * volume instead of hiding the result under Android/data.
     *
     * This deliberately does NOT depend on a running [PlayerService] or a
     * controller link: the exact failure we must diagnose (stuck at 启动中 /
     * START_FAILED) is when no service exists, so the LAN export path is dead.
     * player.log is written under the shared app filesDir, so its tail is
     * available here even across a failed service start. ACTION_CREATE_DOCUMENT
     * is available from API 19, exactly matching this app's minimum SDK.
     */
    private fun chooseDiagnosticExportPath() {
        val fileName = "lmw-player-diag-${settings.deviceId}-${System.currentTimeMillis()}.txt"
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            setType("text/plain")
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            startActivityForResult(intent, DIAGNOSTIC_EXPORT_REQUEST)
        } catch (t: Throwable) {
            // Some stripped Android 4.4/YunOS images have no DocumentsUI at all.
            // Preserve a usable no-adb path instead of turning export into a
            // dead button: save under the app's file-manager-visible directory.
            exportDiagnosticsToFallbackFile(t)
        }
    }

    @Deprecated("Android API 19-compatible document picker callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != DIAGNOSTIC_EXPORT_REQUEST || resultCode != RESULT_OK) return
        val uri = data?.data
        if (uri == null) {
            showDiagnosticExportFailure(
                IllegalStateException("document provider returned no destination Uri"),
            )
            return
        }
        try {
            val bundle = buildLocalDiagnosticText()
            // "wt" explicitly truncates an existing document selected through
            // ACTION_CREATE_DOCUMENT. Plain "w" may leave an old trailing tail
            // with some DocumentsProvider implementations.
            contentResolver.openOutputStream(uri, "wt")?.bufferedWriter()?.use { it.write(bundle) }
                ?: throw IllegalStateException("document provider returned no output stream")
            val destination = uri.toString()
            binding.textExportPath.text = getString(R.string.diag_export_ok_fmt, destination)
            toast(getString(R.string.diag_export_ok_fmt, destination))
        } catch (t: Throwable) {
            showDiagnosticExportFailure(t)
        }
    }

    private fun showDiagnosticExportFailure(t: Throwable) {
        val msg = "${t.javaClass.simpleName}: ${t.message ?: ""}"
        binding.textExportPath.text = getString(R.string.diag_export_failed_fmt, msg)
        toast(getString(R.string.diag_export_failed_fmt, msg))
    }

    private fun exportDiagnosticsToFallbackFile(pickerFailure: Throwable) {
        try {
            val dir = getExternalFilesDir(null) ?: filesDir
            if (!dir.exists() && !dir.mkdirs()) {
                throw IllegalStateException("cannot create ${dir.absolutePath}")
            }
            val file = File(
                dir,
                "lmw-player-diag-${settings.deviceId}-${System.currentTimeMillis()}.txt",
            )
            file.writeText(buildLocalDiagnosticText())
            val destination = file.absolutePath
            binding.textExportPath.text = getString(
                R.string.diag_export_fallback_ok_fmt,
                destination,
                pickerFailure.javaClass.simpleName,
            )
            toast(getString(R.string.diag_export_ok_fmt, destination))
        } catch (writeFailure: Throwable) {
            showDiagnosticExportFailure(writeFailure)
        }
    }

    /** Assemble a self-contained diagnostic text usable with no live service. */
    private fun buildLocalDiagnosticText(): String {
        val service = PlayerService.instance
        return buildString {
            appendLine("===== lan-media-wall player diagnostics =====")
            appendLine("time_ms=${System.currentTimeMillis()}")
            appendLine("app_version=${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            appendLine("android_sdk=${Build.VERSION.SDK_INT}")
            appendLine("device_id=${settings.deviceId}")
            appendLine("device_name=${settings.deviceName}")
            appendLine("group_id=${settings.groupId}")
            appendLine("configured=${settings.isConfigured}")
            appendLine("service_present=${service != null}")
            appendLine("conn_phase=${ConnState.phase}")
            appendLine("conn_detail=${ConnState.detail}")
            appendLine("start_requested_elapsed_ms=$serviceStartElapsedMs")
            appendLine("now_elapsed_ms=${android.os.SystemClock.elapsedRealtime()}")
            // boot-probe: autostart forensics — these hold even with no service.
            appendLine("battery_optimization_ignored=${batteryOptimizationIgnored()}")
            appendLine("boot_receiver_enabled=${bootReceiverEnabled()}")
            appendLine("is_home_candidate=${isHomeCandidate()}")
            appendLine("--- helper ---");   appendLine(describeHelper())
            appendLine("--- restart ---");  appendLine(describeRestart())
            appendLine("--- update ---");   appendLine(describeUpdate())
            appendLine("--- playback ---"); appendLine(describePlayback())
            appendLine("--- cache ---");    appendLine(describeCache())
            appendLine("--- errors ---");   appendLine(describeErrors())
            appendLine("--- probe ---");    appendLine(describeProbe())
            appendLine("--- player.log tail (persisted, survives failed start) ---")
            appendLine(readPlayerLogTail())
            // field-fix+71: universal no-ADB takeover forensics (identity / HOME
            // handlers / our components / heuristic packages / running procs).
            // Read-only and never-throws, safe with a null service.
            appendLine(com.jieoz.lanmediawall.player.diag.TakeoverForensics.build(this@SettingsActivity))
            appendLine("===== boot_audit =====")
            appendLine(readBootAuditTail())
        }
    }

    /** boot-probe: the durable receiver-level breadcrumb log, independent of
     *  PlayerService. Survives a boot where the service never came up. */
    private fun readBootAuditTail(maxBytes: Int = 64 * 1024): String {
        val logFile = File(filesDir, "logs/boot_audit.log")
        val rotated = File(filesDir, "logs/boot_audit.log.1")
        return buildString {
            if (rotated.exists()) append(tailOf(rotated, maxBytes / 2))
            if (logFile.exists()) {
                append(tailOf(logFile, maxBytes))
            } else if (!rotated.exists()) {
                append("no boot_audit.log yet (BootReceiver has not fired since install)")
            }
        }
    }

    /** PowerManager.isIgnoringBatteryOptimizations — API 23+; else "na". */
    private fun batteryOptimizationIgnored(): String = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(android.content.Context.POWER_SERVICE) as? android.os.PowerManager
            "${pm?.isIgnoringBatteryOptimizations(packageName)}"
        } else {
            "na(<23)"
        }
    } catch (e: Exception) {
        "err:${e.message}"
    }

    /** BootReceiver component-enabled state via PackageManager. DEFAULT means
     *  the manifest value (enabled) applies. */
    private fun bootReceiverEnabled(): String = try {
        val cn = android.content.ComponentName(this, "com.jieoz.lanmediawall.player.boot.BootReceiver")
        when (packageManager.getComponentEnabledSetting(cn)) {
            android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> "disabled"
            android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> "enabled"
            else -> "default(manifest)"
        }
    } catch (e: Exception) {
        "err:${e.message}"
    }

    /** Best-effort: does our package own a MAIN+HOME activity (i.e. is the app
     *  the launcher/HOME so it wins the screen after boot)? */
    private fun isHomeCandidate(): String = try {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val matches = packageManager.queryIntentActivities(home, 0)
        val mine = matches.any { it.activityInfo?.packageName == packageName }
        "$mine (home_handlers=${matches.size})"
    } catch (e: Exception) {
        "err:${e.message}"
    }

    /** Read the tail of the persisted player.log without needing the service. */
    private fun readPlayerLogTail(maxBytes: Int = 160 * 1024): String {
        val logFile = File(filesDir, "logs/player.log")
        val rotated = File(filesDir, "logs/player.log.1")
        return buildString {
            if (rotated.exists()) append(tailOf(rotated, maxBytes / 2))
            if (logFile.exists()) {
                append(tailOf(logFile, maxBytes))
            } else if (!rotated.exists()) {
                append("no player.log yet (service may have never created it)")
            }
        }
    }

    private fun tailOf(file: File, maxBytes: Int): String = try {
        val bytes = file.readBytes()
        val slice = if (bytes.size > maxBytes) bytes.copyOfRange(bytes.size - maxBytes, bytes.size) else bytes
        String(slice)
    } catch (e: Exception) {
        "log:${e.message}"
    }

    private fun renderDiagnostics() {
        diagnosticsServicePresent = PlayerService.instance != null
        binding.textDiagStatus.text = getString(R.string.diag_refreshing)
        val helper = describeHelper()
        val restart = describeRestart()
        val update = describeUpdate()
        val playback = describePlayback()
        val cache = describeCache()
        val errors = describeErrors()
        val probe = describeProbe()
        binding.textDiagHint.text = getString(R.string.diag_hint)
        binding.textDiagHelper.text = getString(R.string.diag_helper_fmt, helper)
        binding.textDiagRestart.text = getString(R.string.diag_restart_fmt, restart)
        binding.textDiagUpdate.text = getString(R.string.diag_update_fmt, update)
        binding.textDiagPlayback.text = getString(R.string.diag_playback_fmt, playback)
        binding.textDiagCache.text = getString(R.string.diag_cache_fmt, cache)
        binding.textDiagErrors.text = getString(R.string.diag_errors_fmt, errors)
        binding.textDiagProbe.text = getString(R.string.diag_probe_fmt, probe)
        binding.textDiagStatus.text = when {
            probe.contains("helper=", ignoreCase = true) -> probe
            probe.isNotBlank() -> probe
            else -> getString(R.string.label_diag_status)
        }
    }

    private fun describeHelper(): String {
        // §root-daemon: no more setuid helper file. Report the daemon uid file +
        // live socket peer-probe instead (the only thing that proves it works).
        val uidFile = File("/data/local/tmp/lmw_root_daemon.uid")
        val probe = com.jieoz.lanmediawall.player.update.RootInstaller.probe()
        return buildString {
            append("socket=@lmw_root_daemon")
            append(", uid_file=")
            append(if (uidFile.exists()) "${uidFile.length()}B" else "missing")
            append(", probe=")
            append(if (probe.ready) "ready" else "blocked:${probe.detail}")
        }
    }

    private fun describeRestart(): String {
        val probe = com.jieoz.lanmediawall.player.update.RootInstaller.probe()
        return if (probe.ready) {
            "root daemon ready; app restart routed via local socket"
        } else {
            "root daemon unavailable: ${probe.detail}"
        }
    }

    private fun describeUpdate(): String {
        return buildString {
            append("version=")
            append(BuildConfig.VERSION_NAME)
            append("(")
            append(BuildConfig.VERSION_CODE)
            append(")")
        }
    }

    private fun describePlayback(): String {
        val service = PlayerService.instance
        return if (service == null) {
            "service not ready"
        } else {
            val item = service.currentItemForDebug()
            buildString {
                append("state=")
                append(service.debugPlayState())
                append(", index=")
                append(service.debugIndex())
                append(", item=")
                append(item ?: "none")
                append(", backend=")
                append(service.debugBackend())
                append(", controller=")
                append(service.debugControllerPresent())
                append(", audio_master=")
                append(service.debugAudioMaster())
                append("\n  ab: ")
                append(service.debugBackendMetrics())
            }
        }
    }

    private fun describeCache(): String {
        val service = PlayerService.instance ?: return "service not ready"
        return service.debugCacheSummary()
    }

    private fun describeErrors(): String {
        val service = PlayerService.instance ?: return "service not ready"
        return service.debugErrorsSummary()
    }

    private fun describeProbe(): String {
        val service = PlayerService.instance ?: return "service not ready"
        return service.debugHealthProbeSummary()
    }

    /** §9 self-recovery: confirm, then wipe the connection config and bounce back
     *  to a clean first-boot setup (unconfigured → auto-discover / QR pairing).
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
        startPlayerService()
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
        // §backend-ab: persist the selected video kernel. Takes effect when the
        // kiosk Activity (re)builds the controller — the MainActivity launch below
        // recreates it, so the new kernel is live immediately on Save.
        settings.videoBackend = when (binding.groupVideoBackend.checkedRadioButtonId) {
            R.id.backend_exoplayer -> com.jieoz.lanmediawall.player.media.PlayerBackend.EXOPLAYER.id
            R.id.backend_mediaplayer -> com.jieoz.lanmediawall.player.media.PlayerBackend.MEDIAPLAYER.id
            else -> Settings.VIDEO_BACKEND_AUTO
        }
        settings.markConfigured()

        // Restart the service so it picks up the new connection settings.
        startPlayerService()

        // Rebuild the kiosk task so the Activity-owned playback backend is released
        // and recreated from the just-persisted selection. A plain startActivity()
        // can reuse the existing MainActivity and leave the old backend running.
        startActivity(Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        })
        finish()
    }

    private fun toast(msg: String) =
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()

    companion object {
        private const val DIAGNOSTIC_EXPORT_REQUEST = 0x4C4D
        @Volatile private var serviceStartElapsedMs = 0L
    }
}
