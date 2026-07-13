package com.hamsa.dictate

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.ArrayAdapter
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.hamsa.dictate.databinding.ActivityMainBinding
import kotlinx.coroutines.launch

/**
 * Tela única de onboarding + status, no espírito da janela de Configurações
 * do app de Mac: permissões, download do modelo, idioma e o botão do bubble.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var settings: AppSettings
    private lateinit var modelManager: ModelManager

    private val micPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { refresh() }

    private val notifPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { refresh() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        settings = AppSettings(this)
        modelManager = ModelManager(this)

        binding.micButton.setOnClickListener {
            micPermission.launch(Manifest.permission.RECORD_AUDIO)
        }
        binding.overlayButton.setOnClickListener {
            startActivity(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
            )
        }
        binding.accessibilityButton.setOnClickListener {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        binding.downloadButton.setOnClickListener { downloadModel() }
        binding.bubbleButton.setOnClickListener { toggleBubble() }

        setupLanguageSpinner()

        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun setupLanguageSpinner() {
        val labels = listOf(
            getString(R.string.lang_pt), getString(R.string.lang_en), getString(R.string.lang_auto)
        )
        val codes = listOf("pt", "en", "")
        binding.languageSpinner.adapter =
            ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, labels)
        binding.languageSpinner.setSelection(codes.indexOf(settings.language).coerceAtLeast(0))
        binding.languageSpinner.onItemSelectedListener =
            object : android.widget.AdapterView.OnItemSelectedListener {
                override fun onItemSelected(
                    parent: android.widget.AdapterView<*>?, view: android.view.View?,
                    position: Int, id: Long,
                ) {
                    settings.language = codes[position]
                }
                override fun onNothingSelected(parent: android.widget.AdapterView<*>?) = Unit
            }
    }

    private fun refresh() {
        val micOk = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        val overlayOk = Settings.canDrawOverlays(this)
        val accessibilityOk = HamsaAccessibilityService.isEnabled
        val modelOk = modelManager.installedFiles() != null

        binding.micStatus.text = statusLine(micOk, getString(R.string.perm_mic))
        binding.overlayStatus.text = statusLine(overlayOk, getString(R.string.perm_overlay))
        binding.accessibilityStatus.text = statusLine(accessibilityOk, getString(R.string.perm_accessibility))
        binding.modelStatus.text = statusLine(modelOk, getString(R.string.model_label))

        binding.micButton.isEnabled = !micOk
        binding.overlayButton.isEnabled = !overlayOk
        binding.accessibilityButton.isEnabled = !accessibilityOk
        binding.downloadButton.isEnabled = !modelOk

        val ready = micOk && overlayOk && modelOk
        binding.bubbleButton.isEnabled = ready
        binding.bubbleButton.text = getString(
            if (BubbleService.isRunning) R.string.bubble_stop else R.string.bubble_start
        )
    }

    private fun statusLine(ok: Boolean, label: String) = (if (ok) "✅  " else "⚪  ") + label

    private fun downloadModel() {
        binding.downloadButton.isEnabled = false
        binding.downloadProgress.visibility = android.view.View.VISIBLE
        lifecycleScope.launch {
            try {
                modelManager.ensureModel { fraction ->
                    runOnUiThread {
                        binding.downloadProgress.progress = (fraction * 100).toInt()
                    }
                }
            } catch (e: Exception) {
                binding.modelStatus.text = getString(R.string.model_error, e.message ?: "?")
            } finally {
                binding.downloadProgress.visibility = android.view.View.GONE
                refresh()
            }
        }
    }

    private fun toggleBubble() {
        if (BubbleService.isRunning) BubbleService.stop(this) else BubbleService.start(this)
        binding.bubbleButton.postDelayed({ refresh() }, 300)
    }
}
