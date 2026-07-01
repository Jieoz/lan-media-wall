package com.jieoz.lanmediawall.player

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.jieoz.lanmediawall.player.databinding.ActivitySettingsBinding
import com.jieoz.lanmediawall.player.pair.PairUri
import com.jieoz.lanmediawall.player.pair.PairingScanActivity

/**
 * First-boot setup — protocol_spec §4: custom device_name (persisted), broker
 * address, PSK, group, thumbnail policy. Re-openable later for reconfiguration.
 *
 * The PSK is stored via EncryptedSharedPreferences (see [Settings]); everything
 * else in plain prefs. On save we mark the device configured, (re)start the
 * service, and launch the kiosk player.
 */
class SettingsActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySettingsBinding
    private lateinit var settings: Settings

    /**
     * §15 scan-to-pair launcher. On RESULT_OK we re-parse the returned
     * `lmw://pair?…` URI, apply it to [Settings.applyPairing], and refill the
     * form from the now-updated settings so the operator sees (and can still
     * tweak) what was scanned before saving.
     */
    private val scanPair =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode != RESULT_OK) return@registerForActivityResult
            val raw = result.data?.getStringExtra(PairingScanActivity.EXTRA_PAIR_URI)
            val pairUri = PairUri.parse(raw)
            if (pairUri == null) {
                toast(getString(R.string.scan_pair_invalid)); return@registerForActivityResult
            }
            settings.applyPairing(pairUri)
            prefillFromSettings()
            toast(getString(R.string.scan_pair_applied))
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(applicationContext)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        prefillFromSettings()

        binding.btnScanPair.setOnClickListener {
            scanPair.launch(Intent(this, PairingScanActivity::class.java))
        }
        binding.btnSave.setOnClickListener { save() }
    }

    /** Fill every input from the current [settings] (used on open + post-scan). */
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

    private fun save() {
        val name = binding.inputDeviceName.text.toString().trim()
        val host = binding.inputBrokerHost.text.toString().trim()
        val portText = binding.inputBrokerPort.text.toString().trim()
        val groupId = binding.inputGroupId.text.toString().trim()
        val psk = binding.inputPsk.text.toString()

        if (host.isEmpty()) {
            toast("Broker host is required"); return
        }
        val port = portText.toIntOrNull()
        if (port == null || port !in 1..65535) {
            toast("Broker port must be 1–65535"); return
        }
        // §13/§15.3: PSK is OPTIONAL. v1.1+ defaults to `open` (zero-config, no
        // key). An empty field means "no key" — the player connects to an open
        // broker and signs sig="" (see Envelope.hasUsableKey / AuthMode.OPEN).
        // Only a non-empty PSK enables optional/required signing.

        settings.deviceName = if (name.isEmpty()) settings.deviceId else name
        settings.brokerHost = host
        settings.brokerPort = port
        settings.useWss = binding.inputUseWss.isChecked
        settings.groupId = if (groupId.isEmpty()) "default" else groupId
        settings.psk = psk
        settings.alwaysCollectThumbnails = binding.inputAlwaysThumbs.isChecked
        settings.markConfigured()

        // Restart the service so it picks up the new connection settings.
        val svc = Intent(this, PlayerService::class.java).apply {
            action = PlayerService.ACTION_START
        }
        ContextCompat.startForegroundService(this, svc)

        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }

    private fun toast(msg: String) =
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
}
