package com.orion.subtitles.tv

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom
import java.util.Collections

data class PairingInfo(val host: String, val port: Int, val token: String) {
    fun qrPayload(): String = JSONObject()
        .put("scheme", "orion-tv")
        .put("version", 1)
        .put("host", host)
        .put("port", port)
        .put("token", token)
        .toString()

    companion object {
        const val PORT = 38641
        private const val PREFS = "orion_tv_pairing"
        private const val TOKEN_KEY = "pairing_token"

        fun current(context: Context): PairingInfo? {
            val host = findIPv4Address() ?: return null
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            var token = prefs.getString(TOKEN_KEY, null)
            if (token.isNullOrBlank()) {
                val bytes = ByteArray(24)
                SecureRandom().nextBytes(bytes)
                token = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
                prefs.edit().putString(TOKEN_KEY, token).apply()
            }
            return PairingInfo(host, PORT, token)
        }

        private fun findIPv4Address(): String? {
            return try {
                val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
                    .filter { it.isUp && !it.isLoopback }
                    .sortedBy {
                        val name = it.name.lowercase()
                        when {
                            name.startsWith("wlan") || name.startsWith("wifi") -> 0
                            name.startsWith("eth") -> 1
                            else -> 2
                        }
                    }
                interfaces.asSequence()
                    .flatMap { Collections.list(it.inetAddresses).asSequence() }
                    .filterIsInstance<Inet4Address>()
                    .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
                    ?.hostAddress
            } catch (_: Exception) {
                null
            }
        }
    }
}
