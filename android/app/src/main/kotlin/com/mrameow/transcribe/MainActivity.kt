package com.mrameow.transcribe

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and bridges it to [CaptureService], which records
 * either the microphone or the audio other apps are playing.
 *
 * Channels (shared with the Windows runner):
 *  - MethodChannel "transcribe/control": capabilities, start {source}, stop
 *  - EventChannel "transcribe/audio": Float32List chunks of mono PCM
 */
class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var audioSink: EventChannel.EventSink? = null
    private var pendingStart: MethodChannel.Result? = null
    private var pendingSource: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "transcribe/audio").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    audioSink = events
                }

                override fun onCancel(arguments: Any?) {
                    audioSink = null
                }
            })

        MethodChannel(messenger, "transcribe/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> result.success(
                    mapOf(
                        "system" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
                        "mic" to true,
                        "callHelper" to true,
                    )
                )

                "start" -> start(call.argument<String>("source") ?: "mic", result)
                "callHelperEnabled" -> result.success(CallHelperService.isEnabled(this))
                "openCallHelperSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }

                "openAppSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            .setData(Uri.fromParts("package", packageName, null))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }

                "captions" -> {
                    val text = call.argument<String>("text") ?: ""
                    CallHelperService.pendingText = text
                    if (CaptureService.isRunning) CallHelperService.instance?.showCaptions(text)
                    result.success(null)
                }

                "stop" -> {
                    stopService(Intent(this, CaptureService::class.java))
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        CaptureService.listener = object : CaptureService.Listener {
            override fun onStarted(sampleRate: Int) = mainHandler.post {
                pendingStart?.success(sampleRate)
                pendingStart = null
            }.let {}

            override fun onAudio(samples: FloatArray) = mainHandler.post {
                audioSink?.success(samples)
            }.let {}

            override fun onError(message: String) = mainHandler.post {
                val pending = pendingStart
                if (pending != null) {
                    pending.error("capture_failed", message, null)
                    pendingStart = null
                } else {
                    audioSink?.error("capture_failed", message, null)
                }
            }.let {}

            override fun onStopped() = mainHandler.post {
                audioSink?.endOfStream()
            }.let {}
        }
    }

    override fun onDestroy() {
        if (isFinishing) {
            CaptureService.listener = null
            stopService(Intent(this, CaptureService::class.java))
        }
        super.onDestroy()
    }

    private fun start(source: String, result: MethodChannel.Result) {
        if (pendingStart != null) {
            result.error("busy", "Already starting", null)
            return
        }
        if (source == "system" && Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "Capturing other apps needs Android 10 or newer", null)
            return
        }
        pendingStart = result
        pendingSource = source

        val needed = mutableListOf<String>()
        if (!granted(Manifest.permission.RECORD_AUDIO)) needed += Manifest.permission.RECORD_AUDIO
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !granted(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            needed += Manifest.permission.POST_NOTIFICATIONS
        }
        if (needed.isEmpty()) {
            continueStart()
        } else {
            ActivityCompat.requestPermissions(this, needed.toTypedArray(), REQUEST_PERMISSIONS)
        }
    }

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_PERMISSIONS) return
        if (granted(Manifest.permission.RECORD_AUDIO)) {
            // The notification permission is optional; capture works without it.
            continueStart()
        } else {
            failStart("permission_denied", "Microphone permission is required to capture audio")
        }
    }

    private fun continueStart() {
        if (pendingSource == "system") {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            @Suppress("DEPRECATION")
            startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_PROJECTION)
        } else {
            startCapture(Intent(this, CaptureService::class.java).putExtra(CaptureService.EXTRA_SOURCE, "mic"))
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PROJECTION) return
        if (resultCode == Activity.RESULT_OK && data != null) {
            startCapture(
                Intent(this, CaptureService::class.java)
                    .putExtra(CaptureService.EXTRA_SOURCE, "system")
                    .putExtra(CaptureService.EXTRA_RESULT_CODE, resultCode)
                    .putExtra(CaptureService.EXTRA_RESULT_DATA, data)
            )
        } else {
            failStart("permission_denied", "Screen/audio capture permission was not granted")
        }
    }

    private fun startCapture(intent: Intent) {
        try {
            ContextCompat.startForegroundService(this, intent)
        } catch (e: Exception) {
            failStart("capture_failed", e.message ?: e.toString())
        }
    }

    private fun failStart(code: String, message: String) {
        pendingStart?.error(code, message, null)
        pendingStart = null
    }

    companion object {
        private const val REQUEST_PERMISSIONS = 1001
        private const val REQUEST_PROJECTION = 1002
    }
}
