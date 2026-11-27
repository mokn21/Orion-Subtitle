package com.orion.subtitles.tv

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import java.util.concurrent.ConcurrentHashMap

class OverlayController(private val context: Context) {
    private val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val handler = Handler(Looper.getMainLooper())
    private val views = ConcurrentHashMap<String, TextView>()
    private val expiryTasks = ConcurrentHashMap<String, Runnable>()
    private val entryBackgroundColors = ConcurrentHashMap<String, Int>()
    private val lastTouchedAt = ConcurrentHashMap<String, Long>()
    private val maximumActiveOverlays = 24

    @Volatile private var textColor = Color.WHITE
    @Volatile private var backgroundColor = Color.BLACK
    @Volatile private var backgroundAlpha = 0.72
    @Volatile private var fontScale = 0.68

    fun show(
        id: String,
        text: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        backgroundColorHex: String? = null,
        ttlMs: Long = 2500L
    ) {
        if (!Settings.canDrawOverlays(context)) return
        val metrics = context.resources.displayMetrics
        val rect = OverlayGeometry.toScreenRect(
            x, y, width, height, metrics.widthPixels, metrics.heightPixels
        ) ?: return
        handler.post {
            val existing = views[id]
            if (existing == null && views.size >= maximumActiveOverlays) {
                lastTouchedAt.minByOrNull { it.value }?.key?.let(::removeNow)
            }
            val view = views[id] ?: createTextView().also { views[id] = it }
            val isNewView = existing == null
            if (view.text.toString() != text) view.text = text

            var backgroundChanged = false
            backgroundColorHex?.takeIf { it.startsWith("#") }?.let { hex ->
                runCatching { Color.parseColor(hex) }.getOrNull()?.let { parsed ->
                    if (entryBackgroundColors[id] != parsed) {
                        entryBackgroundColors[id] = parsed
                        backgroundChanged = true
                    }
                }
            }

            val params = (view.layoutParams as? WindowManager.LayoutParams)
                ?: WindowManager.LayoutParams(
                    rect.width,
                    rect.height,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT
                )
            val sizeChanged = params.height != rect.height
            if (isNewView || sizeChanged || backgroundChanged) {
                applyStyle(view, rect.height, entryBackgroundColors[id])
            }
            val layoutChanged = params.width != rect.width ||
                params.height != rect.height ||
                params.x != rect.left ||
                params.y != rect.top ||
                params.gravity != (Gravity.TOP or Gravity.LEFT)
            params.width = rect.width
            params.height = rect.height
            params.gravity = Gravity.TOP or Gravity.LEFT
            params.x = rect.left
            params.y = rect.top
            try {
                if (view.isAttachedToWindow) {
                    if (layoutChanged) windowManager.updateViewLayout(view, params)
                } else {
                    windowManager.addView(view, params)
                }
                lastTouchedAt[id] = android.os.SystemClock.elapsedRealtime()
                scheduleExpiry(id, ttlMs)
            } catch (_: Exception) {
                views.remove(id)
                lastTouchedAt.remove(id)
                entryBackgroundColors.remove(id)
            }
        }
    }

    fun keep(id: String, ttlMs: Long = 3000L) {
        handler.post {
            if (views.containsKey(id)) {
                lastTouchedAt[id] = android.os.SystemClock.elapsedRealtime()
                scheduleExpiry(id, ttlMs)
            }
        }
    }

    fun clear(id: String) {
        handler.post { removeNow(id) }
    }

    fun clearAll() {
        handler.post {
            views.keys.toList().forEach(::removeNow)
        }
    }

    fun updateStyle(json: org.json.JSONObject) {
        json.optString("textColor").takeIf { it.startsWith("#") }?.let {
            runCatching { textColor = Color.parseColor(it) }
        }
        json.optString("backgroundColor").takeIf { it.startsWith("#") }?.let {
            runCatching { backgroundColor = Color.parseColor(it) }
        }
        if (json.has("backgroundAlpha")) {
            backgroundAlpha = json.optDouble("backgroundAlpha", backgroundAlpha).coerceIn(0.0, 1.0)
        }
        if (json.has("fontScale")) {
            fontScale = json.optDouble("fontScale", fontScale).coerceIn(0.2, 1.2)
        }
        handler.post {
            views.forEach { (id, view) ->
                val height = (view.layoutParams as? WindowManager.LayoutParams)?.height ?: 24
                applyStyle(view, height, entryBackgroundColors[id])
            }
        }
    }

    private fun createTextView(): TextView = TextView(context).apply {
        gravity = Gravity.CENTER
        textAlignment = TextView.TEXT_ALIGNMENT_CENTER
        textDirection = TextView.TEXT_DIRECTION_RTL
        layoutDirection = android.view.View.LAYOUT_DIRECTION_RTL
        typeface = Typeface.create("sans-serif", Typeface.BOLD)
        setPadding(2, 0, 2, 0)
        maxLines = 2
        includeFontPadding = false
    }

    private fun applyStyle(view: TextView, height: Int, entryBackground: Int? = null) {
        view.setTextColor(textColor)
        view.setTextSize(TypedValue.COMPLEX_UNIT_PX, (height * fontScale).coerceAtLeast(7.0).toFloat())
        val drawable = GradientDrawable()
        val selectedBackground = entryBackground ?: backgroundColor
        drawable.setColor((selectedBackground and 0x00FFFFFF) or
            ((backgroundAlpha * 255).toInt() shl 24))
        drawable.cornerRadius = 2f
        view.background = drawable
    }

    private fun scheduleExpiry(id: String, ttlMs: Long) {
        expiryTasks.remove(id)?.let(handler::removeCallbacks)
        val task = Runnable { removeNow(id) }
        expiryTasks[id] = task
        handler.postDelayed(task, ttlMs.coerceIn(1000L, 10000L))
    }

    private fun removeNow(id: String) {
        expiryTasks.remove(id)?.let(handler::removeCallbacks)
        entryBackgroundColors.remove(id)
        lastTouchedAt.remove(id)
        views.remove(id)?.let { view ->
            runCatching { if (view.isAttachedToWindow) windowManager.removeView(view) }
        }
    }
}
