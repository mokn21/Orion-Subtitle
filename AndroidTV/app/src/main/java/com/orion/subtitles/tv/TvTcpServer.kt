package com.orion.subtitles.tv

import android.util.Log
import android.os.SystemClock
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicBoolean

class TvTcpServer(
    private val token: String,
    private val overlay: OverlayController,
    private val onStatus: (String) -> Unit
) {
    companion object {
        private const val TAG = "OrionTvServer"
        private const val MAX_LINE_CHARS = 16_384
    }

    private val running = AtomicBoolean(false)
    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var activeSocket: Socket? = null
    private var worker: Thread? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return
        worker = Thread({
            try {
                val server = ServerSocket(PairingInfo.PORT, 1, InetAddress.getByName("0.0.0.0"))
                serverSocket = server
                onStatus("بانتظار اتصال الآيباد")
                while (running.get()) {
                    val client = server.accept()
                    activeSocket = client
                    handleClient(client)
                    activeSocket = null
                }
            } catch (error: Exception) {
                if (running.get()) {
                    Log.e(TAG, "Receiver server stopped", error)
                    onStatus("تعذر تشغيل مستقبل الشبكة: ${error.message ?: "خطأ غير معروف"}")
                }
            } finally {
                runCatching { serverSocket?.close() }
                serverSocket = null
                running.set(false)
            }
        }, "Orion-TV-TCP").apply { isDaemon = true; start() }
    }

    fun stop() {
        running.set(false)
        runCatching { activeSocket?.close() }
        runCatching { serverSocket?.close() }
        worker?.interrupt()
        worker = null
        overlay.clearAll()
        onStatus("المستقبل متوقف")
    }

    private fun handleClient(socket: Socket) {
        socket.use { client ->
            client.tcpNoDelay = true
            val reader = BufferedReader(InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8))
            val writer = OutputStreamWriter(client.getOutputStream(), StandardCharsets.UTF_8)
            val firstLine = reader.readLine() ?: return
            if (firstLine.length > MAX_LINE_CHARS) return
            val hello = runCatching { JSONObject(firstLine) }.getOrNull() ?: return
            if (hello.optString("type") != "hello" || hello.optString("token") != token) {
                runCatching {
                    writer.write(JSONObject().put("type", "error").put("code", "unauthorized").toString() + "\n")
                    writer.flush()
                }
                return
            }
            writer.write(JSONObject().put("type", "hello.ack").put("protocol", 1).toString() + "\n")
            writer.flush()
            onStatus("متصل بالآيباد")
            overlay.clearAll()

            // The iPad sends a lightweight ping every two seconds. A read timeout
            // lets the receiver detect a half-open Wi-Fi connection even when TCP
            // never reports EOF, then clear all overlays without waiting for TTL.
            client.soTimeout = 2_000
            var lastInboundAt = SystemClock.elapsedRealtime()
            while (running.get() && !client.isClosed) {
                val line = try {
                    reader.readLine()
                } catch (_: SocketTimeoutException) {
                    if (SystemClock.elapsedRealtime() - lastInboundAt > 7_000L) break
                    continue
                } ?: break
                lastInboundAt = SystemClock.elapsedRealtime()
                if (line.length > MAX_LINE_CHARS) break
                val message = runCatching { JSONObject(line) }.getOrNull() ?: continue
                handleMessage(message, writer)
            }
        }
        overlay.clearAll()
        if (running.get()) onStatus("انقطع الاتصال — بانتظار الآيباد")
    }

    private fun handleMessage(message: JSONObject, writer: OutputStreamWriter) {
        when (message.optString("type")) {
            "subtitle.show", "subtitle.replace" -> {
                val rect = message.optJSONObject("rect") ?: return
                overlay.show(
                    id = message.optString("id").ifBlank { return },
                    text = message.optString("text"),
                    x = rect.optDouble("x", Double.NaN),
                    y = rect.optDouble("y", Double.NaN),
                    width = rect.optDouble("width", Double.NaN),
                    height = rect.optDouble("height", Double.NaN),
                    backgroundColorHex = message.optString("backgroundColor").takeIf { it.startsWith("#") },
                    ttlMs = message.optLong("ttlMs", 3000L),
                    isSelectedMenuItem = message.optBoolean("selected", false)
                )
            }
            "subtitle.keep" -> overlay.keep(message.optString("id"), message.optLong("ttlMs", 3000L))
            "subtitle.clear" -> overlay.clear(message.optString("id"))
            "subtitle.clearAll" -> overlay.clearAll()
            "style.set" -> message.optJSONObject("style")?.let(overlay::updateStyle)
            "ping" -> {
                runCatching {
                    writer.write(JSONObject().put("type", "pong").put("nonce", message.optString("nonce")).toString() + "\n")
                    writer.flush()
                }
            }
        }
    }
}
