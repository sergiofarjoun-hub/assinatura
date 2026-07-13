package com.hamsa.dictate

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Grava do microfone em 16 kHz mono Float32 (formato nativo do Whisper).
 * Mesmo papel do AudioRecorder.swift do app de Mac.
 */
class AudioRecorder {
    companion object {
        const val SAMPLE_RATE = 16_000
        /** Limite para evitar gravação presa (mesmo valor do Mac: 2 min). */
        const val MAX_SECONDS = 120
        private const val MAX_SAMPLES = SAMPLE_RATE * MAX_SECONDS

        /** Gravações com RMS médio abaixo disso são silêncio/toque acidental. */
        fun isSilence(samples: FloatArray): Boolean {
            if (samples.isEmpty()) return true
            var sum = 0.0
            for (s in samples) sum += (s * s).toDouble()
            return sqrt(sum / samples.size) < 0.0025
        }
    }

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private val chunks = ArrayList<FloatArray>()
    @Volatile private var capturing = false

    /** Callback opcional com o RMS de cada buffer (0…1), para feedback visual. */
    var onLevel: ((Float) -> Unit)? = null

    val isRecording: Boolean get() = capturing

    @SuppressLint("MissingPermission") // checada pelo chamador antes de iniciar
    fun start() {
        if (capturing) return
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT
        )
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT,
            maxOf(minBuffer, SAMPLE_RATE) // ~1 s de folga
        )
        check(rec.state == AudioRecord.STATE_INITIALIZED) { "AudioRecord não inicializou" }

        synchronized(chunks) { chunks.clear() }
        record = rec
        capturing = true
        rec.startRecording()

        thread = Thread {
            val buffer = FloatArray(2048)
            var total = 0
            while (capturing && total < MAX_SAMPLES) {
                val n = rec.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                if (n > 0) {
                    synchronized(chunks) { chunks.add(buffer.copyOf(n)) }
                    total += n
                    var sum = 0.0
                    for (i in 0 until n) sum += (buffer[i] * buffer[i]).toDouble()
                    onLevel?.invoke(min(1f, (sqrt(sum / n) * 12).toFloat()))
                }
            }
        }.also { it.start() }
    }

    /** Para a gravação e devolve todas as amostras capturadas. */
    fun stop(): FloatArray {
        capturing = false
        thread?.join(1000)
        thread = null
        record?.let { runCatching { it.stop() }; it.release() }
        record = null

        synchronized(chunks) {
            val total = chunks.sumOf { it.size }
            val all = FloatArray(total)
            var pos = 0
            for (c in chunks) { c.copyInto(all, pos); pos += c.size }
            chunks.clear()
            return all
        }
    }

    fun cancel() {
        stop()
    }
}
