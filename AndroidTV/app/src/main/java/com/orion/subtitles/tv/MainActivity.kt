package com.orion.subtitles.tv

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
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
    private lateinit var root: LinearLayout
    private lateinit var permissionStatus: TextView
    private lateinit var receiverStatus: TextView
    private lateinit var pairingDetails: TextView
    private lateinit var qrImage: ImageView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildUi()
    }

    override fun onResume() {
        super.onResume()
        refreshUi()
    }

    private fun buildUi() {
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(36, 28, 36, 28)
            setBackgroundColor(Color.rgb(80, 75, 56))
            gravity = Gravity.CENTER_HORIZONTAL
        }
        val scroll = ScrollView(this).apply { isFillViewport = true }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        scroll.addView(content)
        root.addView(scroll, LinearLayout.LayoutParams(-1, -1))

        content.addView(label("ORION SUBTITLES TV", 28f, Color.rgb(248, 243, 217), true))
        content.addView(label("استقبال الترجمة وعرضها فوق مصدر HDMI", 17f, Color.rgb(235, 229, 194), false))

        permissionStatus = label("", 16f, Color.WHITE, false)
        content.addView(permissionStatus)
        content.addView(actionButton("السماح بالظهور فوق التطبيقات") { requestOverlayPermission() })
        content.addView(actionButton("تشغيل مستقبل Orion") { startReceiver() })
        content.addView(actionButton("اختبار ظهور الترجمة") { testOverlay() })
        content.addView(actionButton("إيقاف المستقبل") { startService(Intent(this, TvReceiverService::class.java).setAction(TvReceiverService.ACTION_STOP)) })

        receiverStatus = label("حالة المستقبل: متوقف", 16f, Color.WHITE, false)
        content.addView(receiverStatus)
        content.addView(label("اربط الآيباد والتلفاز بالشبكة نفسها، ثم أدخل عنوان IP والمنفذ ورمز الاقتران الظاهرين أدناه في TV Mode على الآيباد.", 15f, Color.rgb(235, 229, 194), false))

        qrImage = ImageView(this).apply {
            adjustViewBounds = true
            scaleType = ImageView.ScaleType.FIT_CENTER
            contentDescription = "Orion TV pairing QR code"
        }
        content.addView(qrImage, LinearLayout.LayoutParams(260, 260).apply {
            gravity = Gravity.CENTER
            topMargin = 16
            bottomMargin = 8
        })
        pairingDetails = label("", 14f, Color.WHITE, false)
        content.addView(pairingDetails)
        setContentView(root)
    }

    private fun label(text: String, size: Float, color: Int, bold: Boolean): TextView =
        TextView(this).apply {
            this.text = text
            textSize = size
            setTextColor(color)
            gravity = Gravity.CENTER
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(8, 10, 8, 10)
        }

    private fun actionButton(text: String, action: () -> Unit): Button =
        Button(this).apply {
            this.text = text
            isFocusable = true
            isFocusableInTouchMode = true
            setOnClickListener { action() }
            minWidth = 340
        }

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
        receiverStatus.text = "حالة المستقبل: جارٍ التشغيل"
    }

    private fun refreshUi() {
        val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
        permissionStatus.text = if (allowed) "صلاحية الظهور فوق التطبيقات: مفعّلة" else "صلاحية الظهور فوق التطبيقات: غير مفعّلة"
        val pairing = PairingInfo.current(this)
        if (pairing == null) {
            qrImage.setImageDrawable(null)
            pairingDetails.text = "لم يتم العثور على عنوان شبكة محلية. تأكد من اتصال التلفاز بالشبكة."
        } else {
            pairingDetails.text = "عنوان التلفاز: ${pairing.host}\nالمنفذ: ${pairing.port}\nرمز الاقتران: ${pairing.token}\nأدخل هذه البيانات في TV Mode على الآيباد."
            qrImage.setImageBitmap(createQr(pairing.qrPayload()))
        }
    }

    private fun createQr(value: String): Bitmap? = runCatching {
        val matrix = QRCodeWriter().encode(value, BarcodeFormat.QR_CODE, 360, 360)
        Bitmap.createBitmap(360, 360, Bitmap.Config.ARGB_8888).apply {
            for (x in 0 until 360) for (y in 0 until 360) {
                setPixel(x, y, if (matrix[x, y]) Color.BLACK else Color.WHITE)
            }
        }
    }.getOrNull()
}
