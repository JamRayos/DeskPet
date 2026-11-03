package com.example.desk_pet   // <-- change to your app's package name

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/** Shared between MainActivity (Flutter channel) and the service (same process). */
object BlockerState {
    @Volatile var packages: Set<String> = emptySet()
    @Volatile var messages: List<String> = emptyList()
    @Volatile var until: Long = 0L
    val active: Boolean get() = packages.isNotEmpty() && System.currentTimeMillis() < until
}

class BlockerService : AccessibilityService() {

    companion object {
        @Volatile var instance: BlockerService? = null
    }

    private val ui = Handler(Looper.getMainLooper())
    private var overlay: View? = null
    private var shownAt = 0L
    private val autoHide = Runnable { hide() }

    private val ignored = setOf("com.android.systemui", "android")

    private fun imePackages(): Set<String> {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        return imm.enabledInputMethodList.map { it.packageName }.toSet()
    }

    override fun onServiceConnected() { instance = this }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        hide()
        return super.onUnbind(intent)
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(e: AccessibilityEvent?) {
        if (e == null || e.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val pkg = e.packageName?.toString() ?: return

        if (!BlockerState.active) { hide(); return }
        if (pkg in ignored || pkg in imePackages()) return                    // shade, keyboard, system dialogs
        if (pkg == packageName && overlay != null &&
            System.currentTimeMillis() - shownAt < 800) return                // our own overlay appearing

        if (pkg in BlockerState.packages) show() else hide()
    }

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun show() {
        if (overlay != null) return
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager

        val now = System.currentTimeMillis()
        val mins = ((BlockerState.until - now) / 60000 + 1).toInt()
        val msg = (BlockerState.messages.randomOrNull() ?: "Stay focused with me! 🐾")
            .replace("{m}", mins.toString())

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(32), dp(32), dp(32), dp(32))
            setBackgroundColor(Color.parseColor("#FFF8E7"))     // opaque: hides the app below
            isClickable = true                                   // swallow every touch
        }
        root.addView(TextView(this).apply {
            text = "🐾"; setTextSize(TypedValue.COMPLEX_UNIT_SP, 72f); gravity = Gravity.CENTER
        })
        root.addView(TextView(this).apply {
            text = msg; setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            setTextColor(Color.parseColor("#3A3A3A")); gravity = Gravity.CENTER
            setPadding(0, dp(16), 0, dp(32))
        })
        root.addView(Button(this).apply {
            text = "Leave app"
            isAllCaps = false
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setTextColor(Color.parseColor("#3A3A3A"))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#A8C3A0")); cornerRadius = dp(28).toFloat()
            }
            setPadding(dp(40), dp(14), dp(40), dp(14))
            setOnClickListener {
                performGlobalAction(GLOBAL_ACTION_HOME)          // the only way out: go home
                hide()
            }
        })

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.OPAQUE
        )
        try {
            wm.addView(root, lp)
            overlay = root
            shownAt = now
            ui.postDelayed(autoHide, maxOf(0L, BlockerState.until - now))   // lift when focus ends
        } catch (_: Exception) {}
    }

    fun hide() {
        ui.removeCallbacks(autoHide)
        val v = overlay ?: return
        overlay = null
        try { (getSystemService(WINDOW_SERVICE) as WindowManager).removeView(v) } catch (_: Exception) {}
    }
}