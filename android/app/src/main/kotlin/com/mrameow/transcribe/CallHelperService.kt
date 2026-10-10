package com.mrameow.transcribe

import android.accessibilityservice.AccessibilityService
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.widget.TextView

/**
 * Accessibility service that shows a floating caption box over other apps.
 *
 * Besides being handy, this is what makes transcribing calls possible:
 * while a call is active (Google Meet, Zoom, WhatsApp...), Android silences
 * the microphone for every app except the call itself and an accessibility
 * service whose UI is on top. With this service enabled and its caption box
 * showing, [CaptureService] keeps receiving microphone audio.
 */
class CallHelperService : AccessibilityService() {
    private var windowManager: WindowManager? = null
    private var captionView: TextView? = null
    private var params: WindowManager.LayoutParams? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        instance = this
        if (CaptureService.isRunning) showCaptions(pendingText)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        hideCaptions()
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        hideCaptions()
        instance = null
        super.onDestroy()
    }

    private fun dp(value: Float): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics,
    ).toInt()

    @SuppressLint("ClickableViewAccessibility")
    fun showCaptions(text: String) {
        val wm = windowManager ?: return
        captionView?.let {
            it.text = text
            return
        }
        val view = TextView(this).apply {
            this.text = text.ifEmpty { "Transcribe is listening…" }
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            maxLines = 3
            ellipsize = TextUtils.TruncateAt.START
            setPadding(dp(14f), dp(10f), dp(14f), dp(10f))
            background = GradientDrawable().apply {
                cornerRadius = dp(14f).toFloat()
                setColor(Color.argb(200, 20, 18, 40))
            }
        }
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = dp(96f)
            horizontalMargin = 0.03f
        }
        // Drag vertically to move the box out of the way.
        var startY = 0
        var touchY = 0f
        view.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    startY = lp.y
                    touchY = event.rawY
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    lp.y = (startY + (event.rawY - touchY)).toInt().coerceAtLeast(0)
                    wm.updateViewLayout(view, lp)
                    true
                }

                else -> false
            }
        }
        try {
            wm.addView(view, lp)
            captionView = view
            params = lp
        } catch (_: Exception) {
            // Window could not be added (e.g. service being torn down).
        }
    }

    fun hideCaptions() {
        val view = captionView ?: return
        captionView = null
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {
        }
    }

    companion object {
        @Volatile
        var instance: CallHelperService? = null
            private set

        /** Last caption text, shown when the box (re)appears. */
        @Volatile
        var pendingText: String = ""

        fun isEnabled(context: Context): Boolean {
            if (instance != null) return true
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            val name = "${context.packageName}/${CallHelperService::class.java.name}"
            val shortName = "${context.packageName}/.${CallHelperService::class.java.simpleName}"
            return enabled.split(':').any {
                it.equals(name, ignoreCase = true) || it.equals(shortName, ignoreCase = true)
            }
        }
    }
}
