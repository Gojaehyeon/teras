package app.tandem.receiver.net

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Safe-area insets in physical pixels (PROTOCOL.md §3.2). */
data class SafeInsets(val top: Int, val bottom: Int, val left: Int, val right: Int) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("top", top)
            .put("bottom", bottom)
            .put("left", left)
            .put("right", right)

    companion object {
        val ZERO = SafeInsets(0, 0, 0, 0)
    }
}

/** The usable full-screen area, in physical pixels. */
data class ScreenInfo(
    val wPx: Int,
    val hPx: Int,
    val scale: Float,
    val refreshHz: Int,
    val safeInsets: SafeInsets,
) {
    fun toJson(): JSONObject =
        JSONObject()
            .put("wPx", wPx)
            .put("hPx", hPx)
            .put("scale", scale.toDouble())
            .put("refreshHz", refreshHz)
            .put("safeInsets", safeInsets.toJson())
}

/** PROTOCOL.md §3.2 `orientation`. */
enum class Orientation(val wire: String) {
    PORTRAIT("portrait"),
    LANDSCAPE_LEFT("landscapeLeft"),
    LANDSCAPE_RIGHT("landscapeRight"),
    PORTRAIT_UPSIDE_DOWN("portraitUpsideDown"),
    ;

    companion object {
        fun fromWire(value: String?): Orientation =
            entries.firstOrNull { it.wire == value } ?: PORTRAIT
    }
}

/** Everything the receiver advertises about itself in HELLO_ACK. */
data class DeviceProfile(
    val deviceId: String,
    val deviceName: String,
    val model: String,
    val screen: ScreenInfo,
    val orientation: Orientation,
    val codecs: List<String>,
    val maxDecodeWidth: Int,
    val maxDecodeHeight: Int,
    val features: List<String>,
)

/** HELLO, host to receiver (PROTOCOL.md §3.1). */
data class Hello(
    val pv: Int,
    val hostId: String,
    val hostName: String,
    val transport: String,
    val hostNonce: ByteArray,
    val encrypt: Boolean,
    val appName: String,
    val appVersion: String,
    val appBuild: Int,
) {
    val isUsb: Boolean get() = transport.equals("usb", ignoreCase = true)

    override fun equals(other: Any?): Boolean =
        this === other ||
            (
                other is Hello && pv == other.pv && hostId == other.hostId &&
                    hostName == other.hostName && transport == other.transport &&
                    hostNonce.contentEquals(other.hostNonce) && encrypt == other.encrypt
            )

    override fun hashCode(): Int = hostId.hashCode() * 31 + hostNonce.contentHashCode()

    companion object {
        fun parse(payload: ByteArray): Hello {
            val json = Json.obj(payload)
            val nonce = Json.base64(json, "hostNonce")
            if (nonce.size != 16) throw ProtocolException("hostNonce must be 16 bytes, got ${nonce.size}")
            val app = json.optJSONObject("app")
            return Hello(
                pv = json.optInt("pv", 0),
                hostId = json.optString("hostId", ""),
                hostName = json.optString("hostName", ""),
                transport = json.optString("transport", "lan"),
                hostNonce = nonce,
                encrypt = json.optBoolean("encrypt", false),
                appName = app?.optString("name", "") ?: "",
                appVersion = app?.optString("version", "") ?: "",
                appBuild = app?.optInt("build", 0) ?: 0,
            ).also {
                if (it.hostId.isEmpty()) throw ProtocolException("HELLO is missing hostId")
            }
        }
    }
}

/** STREAM_CONFIG, host to receiver (PROTOCOL.md §3.4). */
data class StreamConfig(
    val codec: String,
    val wPx: Int,
    val hPx: Int,
    val fps: Int,
    val desktopW: Int,
    val desktopH: Int,
    val orientation: Orientation,
    val mode: String,
    val cursorBaked: Boolean,
) {
    /** A decoder reset is required only when these three change (§3.4). */
    fun decoderIdentity(): Triple<String, Int, Int> = Triple(codec.lowercase(), wPx, hPx)

    companion object {
        fun parse(payload: ByteArray): StreamConfig {
            val json = Json.obj(payload)
            val desktop = json.optJSONObject("desktop")
            val w = json.optInt("wPx", 0)
            val h = json.optInt("hPx", 0)
            if (w <= 0 || h <= 0) throw ProtocolException("STREAM_CONFIG has a non-positive frame size")
            return StreamConfig(
                codec = json.optString("codec", "hevc"),
                wPx = w,
                hPx = h,
                fps = json.optInt("fps", 60),
                desktopW = desktop?.optInt("w", 0) ?: 0,
                desktopH = desktop?.optInt("h", 0) ?: 0,
                orientation = Orientation.fromWire(json.optString("orientation")),
                mode = json.optString("mode", "extend"),
                cursorBaked = json.optBoolean("cursorBaked", true),
            )
        }
    }
}

/** Receiver-side view of the decoded STATS payload (PROTOCOL.md §7). */
data class StatsSnapshot(
    val fpsDecoded: Double,
    val fpsDropped: Double,
    val decodeMsP50: Double,
    val queued: Int,
    val rttMs: Double,
    val e2eMsP50: Double,
) {
    fun toJsonBytes(): ByteArray =
        JSONObject()
            .put("fpsDecoded", round1(fpsDecoded))
            .put("fpsDropped", round1(fpsDropped))
            .put("decodeMsP50", round1(decodeMsP50))
            .put("queued", queued)
            .put("rttMs", round1(rttMs))
            .put("e2eMsP50", round1(e2eMsP50))
            .toString()
            .toByteArray(Charsets.UTF_8)

    private fun round1(v: Double): Double = Math.round(v * 10.0) / 10.0
}

/** KEY, receiver to host (PROTOCOL.md §6.3). */
data class KeyEvent(
    val down: Boolean,
    val keyCode: Int,
    val text: String,
    val mods: List<String>,
) {
    fun toJsonBytes(): ByteArray {
        val modsArray = JSONArray()
        mods.forEach { modsArray.put(it) }
        return JSONObject()
            .put("down", down)
            .put("keyCode", keyCode)
            .put("text", text)
            .put("mods", modsArray)
            .toString()
            .toByteArray(Charsets.UTF_8)
    }
}

/** JSON helpers shared by every message codec. */
object Json {
    fun obj(payload: ByteArray): JSONObject =
        try {
            JSONObject(String(payload, Charsets.UTF_8))
        } catch (e: JSONException) {
            throw ProtocolException("payload is not a JSON object", e)
        }

    fun bytes(json: JSONObject): ByteArray = json.toString().toByteArray(Charsets.UTF_8)

    fun base64(json: JSONObject, key: String): ByteArray {
        val value = json.optString(key, "")
        if (value.isEmpty()) throw ProtocolException("missing base64 field '$key'")
        return try {
            java.util.Base64.getDecoder().decode(value)
        } catch (e: IllegalArgumentException) {
            throw ProtocolException("field '$key' is not valid base64", e)
        }
    }

    // java.util.Base64 rather than android.util.Base64: it exists from API 26
    // (this app's floor) and, unlike the Android one, it is not a stub in JVM
    // unit tests, so the handshake codecs are covered without a device.
    fun encodeBase64(bytes: ByteArray): String = java.util.Base64.getEncoder().encodeToString(bytes)
}
