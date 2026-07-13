package com.hamsa.dictate

import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Engine de transcrição offline (Whisper via sherpa-onnx/ONNX Runtime).
 * Equivalente ao TranscriptionEngine.swift do app de Mac.
 */
class Transcriber {
    private var recognizer: OfflineRecognizer? = null
    private var loadedLanguage: String? = null
    private var files: ModelManager.ModelFiles? = null

    val isReady: Boolean get() = recognizer != null

    /**
     * Carrega o modelo em memória. `language` = "pt"/"en" ou "" (auto).
     * Recarrega apenas se o idioma mudou.
     */
    suspend fun prepare(files: ModelManager.ModelFiles, language: String) =
        withContext(Dispatchers.Default) {
            if (recognizer != null && loadedLanguage == language) return@withContext
            recognizer?.release()
            recognizer = null

            val config = OfflineRecognizerConfig(
                featConfig = FeatureConfig(sampleRate = AudioRecorder.SAMPLE_RATE, featureDim = 80),
                modelConfig = OfflineModelConfig(
                    whisper = OfflineWhisperModelConfig(
                        encoder = files.encoder,
                        decoder = files.decoder,
                        language = language,
                        task = "transcribe",
                    ),
                    tokens = files.tokens,
                    modelType = "whisper",
                    numThreads = Runtime.getRuntime().availableProcessors().coerceIn(2, 4),
                    provider = "cpu",
                ),
            )
            recognizer = OfflineRecognizer(config = config)
            loadedLanguage = language
            this@Transcriber.files = files
        }

    /** Transcreve amostras 16 kHz mono Float32. */
    suspend fun transcribe(samples: FloatArray): String = withContext(Dispatchers.Default) {
        val rec = recognizer ?: error("Modelo ainda não carregado")
        val stream = rec.createStream()
        try {
            stream.acceptWaveform(samples, AudioRecorder.SAMPLE_RATE)
            rec.decode(stream)
            postProcess(rec.getResult(stream).text)
        } finally {
            stream.release()
        }
    }

    fun release() {
        recognizer?.release()
        recognizer = null
        loadedLanguage = null
    }

    companion object {
        /** Mesma limpeza mínima do Mac: colapsa espaços e capitaliza. */
        fun postProcess(text: String): String {
            var cleaned = text.replace(Regex("\\s+"), " ").trim()
            if (cleaned.isNotEmpty() && cleaned.first().isLowerCase()) {
                cleaned = cleaned.first().uppercase() + cleaned.substring(1)
            }
            return cleaned
        }
    }
}
