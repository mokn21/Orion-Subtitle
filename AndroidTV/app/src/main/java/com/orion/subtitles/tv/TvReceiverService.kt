package com.orion.subtitles.tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.provider.Settings

class TvReceiverService : Service() {
    companion object {
        const val ACTION_START = "com.orion.subtitles.tv.START"
        const val ACTION_TEST = "com.orion.subtitles.tv.TEST"
        const val ACTION_STOP = "com.orion.subtitles.tv.STOP"
        const val ACTION_STATUS = "com.orion.subtitles.tv.STATUS"
        const val EXTRA_STATUS = "status"
        private const val CHANNEL_ID = "orion_tv_receiver"
        private const val NOTIFICATION_ID = 4107
    }

    private var overlay: OverlayController? = null
    private var server: TvTcpServer? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_TEST -> {
                startReceiverIfNeeded()
                overlay?.show("orion-tv-test", "اختبار Orion TV", 0.25, 0.40, 0.50, 0.16, ttlMs = 5000L)
            }
            else -> startReceiverIfNeeded()
        }
        return START_STICKY
    }

    private fun publishStatus(status: String) {
        getSharedPreferences("orion_tv", MODE_PRIVATE).edit().putString("receiver_status", status).apply()
        sendBroadcast(Intent(ACTION_STATUS).setPackage(packageName).putExtra(EXTRA_STATUS, status))
    }

    private fun startReceiverIfNeeded() {
        if (!Settings.canDrawOverlays(this)) {
            publishStatus("صلاحية العرض فوق التطبيقات غير مفعّلة")
            stopSelf()
            return
        }
        createNotificationChannel()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("Orion Subtitles TV")
            .setContentText("مستقبل الترجمة يعمل على الشبكة المحلية")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        if (server != null) return
        overlay = OverlayController(this)
        val pairing = PairingInfo.current(this)
        if (pairing == null) {
            publishStatus("تعذر تحديد عنوان التلفزيون")
            stopSelf()
            return
        }
        publishStatus("المستقبل يعمل — بانتظار اتصال الآيباد")
        server = TvTcpServer(pairing.token, overlay!!) { status ->
            android.util.Log.i("OrionTvService", status)
            publishStatus(status)
        }.also { it.start() }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Orion TV receiver", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    override fun onDestroy() {
        server?.stop()
        server = null
        overlay?.clearAll()
        overlay = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        publishStatus("المستقبل متوقف")
        super.onDestroy()
    }
}
