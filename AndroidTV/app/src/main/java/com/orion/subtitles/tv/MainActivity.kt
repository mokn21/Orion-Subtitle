package com.orion.subtitles.tv

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter

class MainActivity : Activity() {
    private lateinit var permissionStatus: TextView
    private lateinit var receiverStatus: TextView
    private lateinit var pairingDetails: TextView
    private lateinit var qrImage: ImageView

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent?.getStringExtra(TvReceiverService.EXTRA_STATUS)?.let {
                receiverStatus.text = it
                receiverStatus.setTextColor(if (it.contains("متصل")) CREAM else MUTED)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildUi()
    }

    override fun onResume() {
        super.onResume()
        val filter = IntentFilter(TvReceiverService.ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(statusReceiver, filter)
        }
        refreshUi()
    }

    override fun onPause() {
        runCatching { unregisterReceiver(statusReceiver) }
        super.onPause()
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(34), dp(22), dp(34), dp(22))
            setBackgroundColor(BG)
            layoutDirection = View.LAYOUT_DIRECTION_LTR
        }
        setContentView(root)

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutDirection = View.LAYOUT_DIRECTION_LTR
        }
        val logo = ImageView(this).apply {
            setImageResource(com.orion.subtitles.tv.R.drawable.orion_launcher_icon)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        header.addView(logo, LinearLayout.LayoutParams(dp(88), dp(88)))
        val brand = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), 0, 0, 0)
        }
        brand.addView(text("ORION", 25f, CREAM, true, Gravity.START))
        brand.addView(text("SUBTITLES  •  TV RECEIVER", 11f, MUTED, true, Gravity.START))
        header.addView(brand, LinearLayout.LayoutParams(0, -2, 1f))
        val topBadge = text("HDMI OVERLAY", 12f, CREAM, true, Gravity.CENTER).apply {
            setPadding(dp(16), dp(9), dp(16), dp(9))
            background = pill(PANEL_ALT, OLIVE)
        }
        header.addView(topBadge)
        root.addView(header)

        val subtitle = text("استقبل ترجمتك على التلفزيون، واعرضها فوق صورة جهاز الألعاب", 16f, MUTED, false, Gravity.START).apply {
            setPadding(dp(4), dp(8), 0, dp(18))
        }
        root.addView(subtitle)

        val body = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.FILL
            layoutDirection = View.LAYOUT_DIRECTION_LTR
        }
        root.addView(body, LinearLayout.LayoutParams(-1, 0, 1f))

        val controlCard = card()
        body.addView(controlCard, LinearLayout.LayoutParams(0, -1, 1.05f).apply {
            marginEnd = dp(14)
        })
        controlCard.addView(sectionTitle("حالة النظام", "SYSTEM STATUS"))
        permissionStatus = text("صلاحية العرض فوق التطبيقات: جارٍ التحقق", 15f, CREAM, false, Gravity.START).apply {
            setPadding(dp(14), dp(13), dp(14), dp(13))
            background = pill(PANEL_ALT, STROKE)
        }
        controlCard.addView(permissionStatus, matchWrap().apply { topMargin = dp(12) })

        receiverStatus = text("المستقبل متوقف", 15f, MUTED, true, Gravity.START).apply {
            setPadding(dp(14), dp(13), dp(14), dp(13))
            background = pill(PANEL_ALT, STROKE)
        }
        controlCard.addView(receiverStatus, matchWrap().apply { topMargin = dp(9) })

        controlCard.addView(text("التحكم", 13f, MUTED, true, Gravity.START).apply {
            setPadding(dp(3), dp(16), 0, dp(6))
        })
        controlCard.addView(actionButton("تشغيل المستقبل", true) { startReceiver() }, matchWrap().apply { topMargin = dp(5) })
        controlCard.addView(actionButton("اختبار ظهور الترجمة", false) { testOverlay() }, matchWrap().apply { topMargin = dp(8) })
        controlCard.addView(actionButton("إيقاف المستقبل", false) { stopReceiver() }, matchWrap().apply { topMargin = dp(8) })
        controlCard.addView(text("يجب أن يكون الآيباد والتلفزيون على شبكة Wi-Fi نفسها.", 12f, MUTED, false, Gravity.START).apply {
            setPadding(dp(4), dp(12), dp(4), 0)
        })

        val pairingCard = card()
        body.addView(pairingCard, LinearLayout.LayoutParams(0, -1, 1.2f))
        pairingCard.addView(sectionTitle("ربط الآيباد", "PAIR YOUR IPAD"))
        val pairingBody = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutDirection = View.LAYOUT_DIRECTION_LTR
        }
        pairingCard.addView(pairingBody, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = dp(10) })
        qrImage = ImageView(this).apply {
            adjustViewBounds = true
            scaleType = ImageView.ScaleType.FIT_CENTER
            contentDescription = "Orion TV pairing QR code"
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = pill(CREAM, CREAM)
        }
        pairingBody.addView(qrImage, LinearLayout.LayoutParams(dp(176), dp(176)).apply {
            marginEnd = dp(18)
        })
        val detailsColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
        }
        detailsColumn.addView(text("امسح الرمز أو أدخل البيانات يدويًا في TV Mode على الآيباد.", 14f, CREAM, false, Gravity.START))
        pairingDetails = text("", 13f, MUTED, false, Gravity.START).apply {
            setPadding(0, dp(12), 0, 0)
        }
        detailsColumn.addView(pairingDetails)
        pairingBody.addView(detailsColumn, LinearLayout.LayoutParams(0, -2, 1f))
        pairingCard.addView(text("اتصال محلي مباشر • لا يتم إرسال صورة اللعبة أو صوتها", 11f, MUTED, false, Gravity.START).apply {
            setPadding(dp(2), dp(8), 0, 0)
        })
    }

    private fun card() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(18), dp(20), dp(18))
        background = rounded(PANEL, STROKE, 18f)
    }

    private fun sectionTitle(arabic: String, english: String): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutDirection = View.LAYOUT_DIRECTION_LTR
        }
        row.addView(text(arabic, 19f, CREAM, true, Gravity.START), LinearLayout.LayoutParams(0, -2, 1f))
        row.addView(text(english, 10f, OLIVE, true, Gravity.END))
        return row
    }

    private fun text(value: String, size: Float, color: Int, bold: Boolean, gravity: Int) =
        TextView(this).apply {
            text = value
            textSize = size
            setTextColor(color)
            this.gravity = gravity or Gravity.CENTER_VERTICAL
            if (bold) setTypeface(typeface, Typeface.BOLD)
            includeFontPadding = false
        }

    private fun actionButton(value: String, primary: Boolean, action: () -> Unit) =
        Button(this).apply {
            text = value
            textSize = 14f
            isAllCaps = false
            isFocusable = true
            isFocusableInTouchMode = true
            setTextColor(if (primary) BG else CREAM)
            minHeight = dp(48)
            minimumHeight = dp(48)
            background = rounded(if (primary) OLIVE else PANEL_ALT, if (primary) OLIVE else STROKE, 12f)
            setPadding(dp(12), dp(7), dp(12), dp(7))
            setOnFocusChangeListener { view, focused ->
                view.background = rounded(
                    if (primary) OLIVE else PANEL_ALT,
                    if (focused) CREAM else if (primary) OLIVE else STROKE,
                    12f
                )
            }
            setOnClickListener { action() }
        }

    private fun rounded(fill: Int, stroke: Int, radius: Float) = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = dp(radius.toInt()).toFloat()
        setStroke(dp(1), stroke)
    }

    private fun pill(fill: Int, stroke: Int) = rounded(fill, stroke, 12f)

    private fun matchWrap() = LinearLayout.LayoutParams(-1, -2)

    private fun refreshUi() {
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
        permissionStatus.text = if (allowed) "صلاحية العرض فوق التطبيقات: مفعّلة" else "صلاحية العرض فوق التطبيقات: غير مفعّلة"
        permissionStatus.setTextColor(if (allowed) OLIVE else CREAM)
        val saved = getSharedPreferences("orion_tv", MODE_PRIVATE)
        receiverStatus.text = saved.getString("receiver_status", "المستقبل متوقف") ?: "المستقبل متوقف"
        val pairing = PairingInfo.current(this)
        if (pairing == null) {
            qrImage.setImageDrawable(null)
            pairingDetails.text = "تعذر قراءة عنوان الشبكة. تأكد من اتصال التلفزيون بالإنترنت أو بالشبكة المحلية."
        } else {
            pairingDetails.text = "عنوان التلفزيون  ${pairing.host}\nالمنفذ  ${pairing.port}\nرمز الاقتران  ${pairing.token}"
            qrImage.setImageBitmap(createQr(pairing.qrPayload()))
        }
    }

    private fun createQr(value: String): android.graphics.Bitmap? = runCatching {
        val matrix = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, 360, 360)
        android.graphics.Bitmap.createBitmap(360, 360, android.graphics.Bitmap.Config.ARGB_8888).apply {
            for (x in 0 until 360) for (y in 0 until 360) {
                setPixel(x, y, if (matrix.get(x, y)) Color.BLACK else Color.WHITE)
            }
        }
    }.getOrNull()

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
        }
    }

    private fun testOverlay() {
        if (!Settings.canDrawOverlays(this)) {
            requestOverlayPermission()
            return
        }
        val intent = Intent(this, TvReceiverService::class.java).setAction(TvReceiverService.ACTION_TEST)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    private fun startReceiver() {
        if (!Settings.canDrawOverlays(this)) {
            requestOverlayPermission()
            return
        }
        val intent = Intent(this, TvReceiverService::class.java).setAction(TvReceiverService.ACTION_START)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
        receiverStatus.text = "جارٍ تشغيل المستقبل — بانتظار الآيباد"
        receiverStatus.setTextColor(CREAM)
    }

    private fun stopReceiver() {
        startService(Intent(this, TvReceiverService::class.java).setAction(TvReceiverService.ACTION_STOP))
        receiverStatus.text = "المستقبل متوقف"
        receiverStatus.setTextColor(MUTED)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun dp(value: Float) = (value * resources.displayMetrics.density).toInt()

    companion object {
        private val BG = Color.rgb(25, 27, 24)
        private val PANEL = Color.rgb(43, 46, 39)
        private val PANEL_ALT = Color.rgb(34, 37, 31)
        private val CREAM = Color.rgb(248, 243, 217)
        private val MUTED = Color.rgb(205, 199, 166)
        private val OLIVE = Color.rgb(185, 178, 138)
        private val STROKE = Color.rgb(80, 75, 56)
    }
}
