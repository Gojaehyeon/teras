package app.teras.receiver.net

/**
 * Wire constants from PROTOCOL.md. Everything on the wire is big-endian and
 * every frame is `[u32 length][u8 type][payload]` where `length = 1 + payload`.
 */
object Protocol {
    const val VERSION = 1
    const val PORT = 41777

    /** `length` covers the type byte, so the smallest legal frame body is 1. */
    const val MIN_LENGTH = 1
    const val MAX_LENGTH = 16 * 1024 * 1024

    const val SERVICE_TYPE = "_teras._tcp"
    const val PLATFORM = "android"

    /** Peer must answer a PING inside this window or the link is considered dead. */
    const val PING_INTERVAL_MS = 1_000L
    const val PONG_TIMEOUT_MS = 3_000L
    const val STATS_INTERVAL_MS = 1_000L

    const val PAIR_MAX_ATTEMPTS = 3
}

object MessageType {
    const val HELLO: Byte = 0x01
    const val HELLO_ACK: Byte = 0x02
    const val PAIR_REQUIRED: Byte = 0x03
    const val PAIR: Byte = 0x04
    const val PAIR_OK: Byte = 0x05
    const val PAIR_FAIL: Byte = 0x06
    const val AUTH: Byte = 0x07
    const val AUTH_OK: Byte = 0x08
    const val AUTH_FAIL: Byte = 0x09
    const val STREAM_CONFIG: Byte = 0x10
    const val READY: Byte = 0x11
    const val VIDEO: Byte = 0x12
    const val KEYFRAME_REQUEST: Byte = 0x13
    const val DEVICE_CONFIG: Byte = 0x14
    const val TOUCH: Byte = 0x20
    const val SCROLL: Byte = 0x21
    const val KEY: Byte = 0x22
    const val POINTER: Byte = 0x23
    const val PING: Byte = 0x30
    const val PONG: Byte = 0x31
    const val STATS: Byte = 0x32
    const val BYE: Byte = 0x40
    const val ENC: Byte = 0x7F

    fun name(type: Byte): String =
        when (type) {
            HELLO -> "HELLO"
            HELLO_ACK -> "HELLO_ACK"
            PAIR_REQUIRED -> "PAIR_REQUIRED"
            PAIR -> "PAIR"
            PAIR_OK -> "PAIR_OK"
            PAIR_FAIL -> "PAIR_FAIL"
            AUTH -> "AUTH"
            AUTH_OK -> "AUTH_OK"
            AUTH_FAIL -> "AUTH_FAIL"
            STREAM_CONFIG -> "STREAM_CONFIG"
            READY -> "READY"
            VIDEO -> "VIDEO"
            KEYFRAME_REQUEST -> "KEYFRAME_REQUEST"
            DEVICE_CONFIG -> "DEVICE_CONFIG"
            TOUCH -> "TOUCH"
            SCROLL -> "SCROLL"
            KEY -> "KEY"
            POINTER -> "POINTER"
            PING -> "PING"
            PONG -> "PONG"
            STATS -> "STATS"
            BYE -> "BYE"
            ENC -> "ENC"
            else -> "0x%02X".format(type)
        }
}

/** A decoded frame: the type byte plus everything after it. */
data class Frame(val type: Byte, val payload: ByteArray) {
    override fun equals(other: Any?): Boolean =
        this === other ||
            (other is Frame && type == other.type && payload.contentEquals(other.payload))

    override fun hashCode(): Int = 31 * type.toInt() + payload.contentHashCode()

    override fun toString(): String = "Frame(${MessageType.name(type)}, ${payload.size} bytes)"
}

/** Any violation of the wire contract. The connection must be closed. */
class ProtocolException(message: String, cause: Throwable? = null) : Exception(message, cause)
