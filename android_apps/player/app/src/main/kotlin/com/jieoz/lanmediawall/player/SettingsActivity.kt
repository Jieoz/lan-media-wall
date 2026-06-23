package com.jieoz.lanmediawall.player

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.jieoz.lanmediawall.player.databinding.ActivitySettingsBinding

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(applicationContext)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Prefill with current values (device_name defaults to device_id).
        binding.inputDeviceName.setText(
            if (settings.isConfigured) settings.deviceName else "",
        )
        binding.inputBrokerHost.setText(settings.brokerHost)
        binding.inputBrokerPort.setText(settings.brokerPort.toString())
        binding.inputUseWss.isChecked = settings.useWss
        binding.inputGroupId.setText(settings.groupId)
        binding.inputPsk.setText(if (settings.psk == Settings.DEFAULT_PSK) "" else settings.psk)
        binding.inputAlwaysThumbs.isChecked = settings.alwaysCollectThumbnails

        binding.btnSave.setOnClickListener { save() }
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
        if (psk.isEmpty()) {
            toast("PSK is required"); return
        }

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
