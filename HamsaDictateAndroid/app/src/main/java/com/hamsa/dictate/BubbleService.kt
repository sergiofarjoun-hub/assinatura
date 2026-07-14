package com.hamsa.dictate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * O coração do app: bubble flutuante estilo Wispr Flow.
 * Segurar = gravar; soltar = transcrever e inserir no campo focado.
 * Arrastar move o bubble (e cancela a gravação daquele toque).
 */
class BubbleService : Service() {

    companion object {
        private const val CHANNEL_ID = "hamsa_bubble"
        private const val NOTIFICATION_ID = 1

        @Volatile var isRunning = false
            private set

        fun start(context: Context) {
            context.startForegroundService(Intent(context, BubbleService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BubbleService::class.java))
        }
    }

    private enum class State { LOADING, IDLE, RECORDING, TRANSCRIBING }

    private lateinit var windowManager: WindowManager
    private var bubble: FrameLayout? = null
    private var icon: ImageView? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private val recorder = AudioRecorder()
    private val transcriber = Transcriber()
    private lateinit var modelManager: ModelManager
    private lateinit var settings: AppSettings

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var prepareJob: Job? = null
    private var state = State.LOADING
        set(value) {
            field = value
            icon?.alpha = if (value == State.LOADING) 0.4f else 1f
            bubble?.background = getDrawable(
                when (value) {
                    State.RECORDING -> R.drawable.bubble_recording
                    State.TRANSCRIBING -> R.drawable.bubble_busy
                    else -> R.drawable.bubble_idle
                }
            )
        }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        modelManager = ModelManager(this)
        settings = AppSettings(this)
        windowManager = getSystemService(WindowManager::class.java)

        startForegroundWithNotification()
        addBubble()
        prepareModel()
    }

    override fun onDestroy() {
        recorder.cancel()
        transcriber.release()
        prepareJob?.cancel()
        bubble?.let { runCatching { windowManager.removeView(it) } }
        bubble = null
        isRunning = false
        super.onDestroy()
    }

    // MARK: modelo

    private fun prepareModel() {
        prepareJob = scope.launch {
            try {
                state = State.LOADING
                val files = modelManager.ensureModel { /* progresso já mostrado na MainActivity */ }
                transcriber.prepare(files, settings.language)
                state = State.IDLE
            } catch (e: Exception) {
                toast(getString(R.string.model_error, e.message ?: "?"))
                stopSelf()
            }
        }
    }

    // MARK: bubble

    private fun addBubble() {
        val size = (56 * resources.displayMetrics.density).toInt()
        val container = FrameLayout(this)
        val mic = ImageView(this).apply {
            setImageResource(R.drawable.ic_mic)
            val pad = size / 4
            setPadding(pad, pad, pad, pad)
        }
        container.addView(mic, FrameLayout.LayoutParams(size, size))

        val params = WindowManager.LayoutParams(
            size, size,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // NOT_FOCUSABLE: o foco (e o teclado) ficam no app de baixo —
            // crítico para o campo de texto continuar focado, como no Mac.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = resources.displayMetrics.widthPixels - size - 24
            y = resources.displayMetrics.heightPixels / 2
        }

        container.setOnTouchListener(BubbleTouchListener(params))

        windowManager.addView(container, params)
        bubble = container
        icon = mic
        layoutParams = params
        state = State.LOADING
    }

    /** Segurar = push-to-talk; arrastar além do slop = mover o bubble. */
    private inner class BubbleTouchListener(
        private val params: WindowManager.LayoutParams,
    ) : View.OnTouchListener {
        private val touchSlop = ViewConfiguration.get(this@BubbleService).scaledTouchSlop
        private var downRawX = 0f
        private var downRawY = 0f
        private var startX = 0
        private var startY = 0
        private var dragging = false

        override fun onTouch(v: View, event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = params.x
                    startY = params.y
                    dragging = false
                    beginRecording()
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (!dragging && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        dragging = true
                        // Virou arrasto: cancela o push-to-talk deste toque.
                        cancelRecording()
                    }
                    if (dragging) {
                        params.x = (startX + dx).toInt()
                        params.y = (startY + dy).toInt()
                        bubble?.let { windowManager.updateViewLayout(it, params) }
                    }
                    return true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (!dragging) finishRecordingAndInsert()
                    return true
                }
            }
            return false
        }
    }

    // MARK: pipeline de ditado (mesmo desenho do DictationController do Mac)

    private fun beginRecording() {
        if (state != State.IDLE) return
        try {
            recorder.start()
            state = State.RECORDING
        } catch (e: Exception) {
            toast(getString(R.string.record_error, e.message ?: "?"))
        }
    }

    private fun cancelRecording() {
        if (state != State.RECORDING) return
        recorder.cancel()
        state = State.IDLE
    }

    private fun finishRecordingAndInsert() {
        if (state != State.RECORDING) return
        val samples = recorder.stop()

        val seconds = samples.size.toFloat() / AudioRecorder.SAMPLE_RATE
        if (seconds < 0.3f || AudioRecorder.isSilence(samples)) {
            state = State.IDLE
            return
        }

        state = State.TRANSCRIBING
        scope.launch {
            try {
                val text = transcriber.transcribe(samples)
                if (text.isNotEmpty()) deliver(text)
            } catch (e: Exception) {
                toast(getString(R.string.transcribe_error, e.message ?: "?"))
            } finally {
                state = State.IDLE
            }
        }
    }

    private fun deliver(text: String) {
        val service = HamsaAccessibilityService.instance
        if (service == null) {
            copyToClipboard(text)
            toast(getString(R.string.accessibility_missing_toast))
            return
        }
        val inserted = service.insertText(text)
        if (!inserted) toast(getString(R.string.clipboard_fallback_toast))
    }

    private fun copyToClipboard(text: String) {
        val clipboard = getSystemService(android.content.ClipboardManager::class.java)
        clipboard.setPrimaryClip(android.content.ClipData.newPlainText("HamsaDictate", text))
    }

    // MARK: infra

    private fun startForegroundWithNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, getString(R.string.app_name), NotificationManager.IMPORTANCE_MIN)
        )
        val contentIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle(getString(R.string.notification_title))
            .setContentIntent(contentIntent)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }
}
