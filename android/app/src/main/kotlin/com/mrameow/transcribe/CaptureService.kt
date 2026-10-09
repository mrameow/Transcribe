package com.mrameow.transcribe

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * Foreground service that records audio so transcription keeps running while
 * the user is in another app (e.g. a meeting or video player).
 *
 * "system" mode uses AudioPlaybackCapture (Android 10+), which records what
 * other apps play. Apps can opt out of being captured, and Android never
 * allows capturing voice-call audio this way, so for calls the microphone
 * mode (with the call on speaker) is the fallback.
 */
class CaptureService : Service() {
    interface Listener {
        fun onStarted(sampleRate: Int)
        fun onAudio(samples: FloatArray)
        fun onError(message: String)
        fun onStopped()
    }

    @Volatile
    private var running = false
    private var thread: Thread? = null
    private var record: AudioRecord? = null
    private var projection: MediaProjection? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        stopCapture()
        val system = intent.getStringExtra(EXTRA_SOURCE) == "system"
        try {
            goForeground(system)
            record = if (system) createPlaybackRecord(intent) else createMicRecord()
            startReading(record!!)
            listener?.onStarted(SAMPLE_RATE)
        } catch (e: Exception) {
            listener?.onError(e.message ?: e.toString())
            stopCapture()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun goForeground(system: Boolean) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Transcription", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Transcribing")
            .setContentText(if (system) "Listening to audio from other apps" else "Listening to the microphone")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val type = if (system) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun audioFormat(): AudioFormat = AudioFormat.Builder()
        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
        .setSampleRate(SAMPLE_RATE)
        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
        .build()

    private fun bufferBytes(): Int = maxOf(
        AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT),
        SAMPLE_RATE * 2, // one second
    )

    @SuppressLint("MissingPermission") // Checked by MainActivity before starting.
    private fun createMicRecord(): AudioRecord {
        val r = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferBytes(),
        )
        check(r.state == AudioRecord.STATE_INITIALIZED) { "Could not open the microphone" }
        return r
    }

    @SuppressLint("MissingPermission", "NewApi")
    private fun createPlaybackRecord(intent: Intent): AudioRecord {
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val data: Intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        } ?: error("Missing screen capture permission")

        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mp = manager.getMediaProjection(resultCode, data) ?: error("Screen capture was not allowed")
        projection = mp
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                // The user tapped "stop sharing" in the system UI.
                stopCapture()
                stopSelf()
            }
        }, Handler(Looper.getMainLooper()))

        val config = AudioPlaybackCaptureConfiguration.Builder(mp)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val r = AudioRecord.Builder()
            .setAudioFormat(audioFormat())
            .setBufferSizeInBytes(bufferBytes())
            .setAudioPlaybackCaptureConfig(config)
            .build()
        check(r.state == AudioRecord.STATE_INITIALIZED) { "Could not start audio capture" }
        return r
    }

    private fun startReading(r: AudioRecord) {
        r.startRecording()
        running = true
        thread = Thread({
            val chunk = ShortArray(SAMPLE_RATE / 10) // 100 ms
            while (running) {
                val n = r.read(chunk, 0, chunk.size)
                if (n > 0) {
                    listener?.onAudio(FloatArray(n) { chunk[it] / 32768f })
                } else if (n < 0) {
                    if (running) listener?.onError("Audio capture stopped (error $n)")
                    break
                }
            }
        }, "audio-capture").also { it.start() }
    }

    private fun stopCapture() {
        val wasRunning = running || record != null
        running = false
        try {
            record?.stop()
        } catch (_: IllegalStateException) {
        }
        thread?.join(500)
        thread = null
        record?.release()
        record = null
        projection?.stop()
        projection = null
        if (wasRunning) listener?.onStopped()
    }

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_SOURCE = "source"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val SAMPLE_RATE = 16000
        private const val CHANNEL_ID = "transcription"
        private const val NOTIFICATION_ID = 1

        @Volatile
        var listener: Listener? = null
    }
}
