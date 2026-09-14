package app.teras.receiver.net

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One VIDEO frame, PROTOCOL.md §4. */
class VideoFrame(
    val flags: Int,
    val captureTimestampUs: Long,
    val seq: Int,
    val accessUnit: ByteArray,
    val accessUnitOffset: Int,
    val accessUnitLength: Int,
) {
    val isKeyframe: Boolean get() = (flags and FLAG_KEYFRAME) != 0
    val hasParameterSets: Boolean get() = (flags and FLAG_PARAMETER_SETS) != 0
    val isDiscontinuity: Boolean get() = (flags and FLAG_DISCONTINUITY) != 0

    companion object {
        const val FLAG_KEYFRAME = 0x01
        const val FLAG_PARAMETER_SETS = 0x02
        const val FLAG_DISCONTINUITY = 0x04

        /** `[u8 flags][u64 captureTimestampUs][u32 seq]` then the Annex-B unit. */
        const val HEADER_BYTES = 13

        fun parse(payload: ByteArray): VideoFrame {
            if (payload.size < HEADER_BYTES) {
                throw ProtocolException("VIDEO frame shorter than its ${HEADER_BYTES}-byte header")
            }
            val buffer = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
            val flags = buffer.get().toInt() and 0xFF
            val timestamp = buffer.long
            val seq = buffer.int
            return VideoFrame(
                flags = flags,
                captureTimestampUs = timestamp,
                seq = seq,
                accessUnit = payload,
                accessUnitOffset = HEADER_BYTES,
                accessUnitLength = payload.size - HEADER_BYTES,
            )
        }

        fun encode(
            flags: Int,
            captureTimestampUs: Long,
            seq: Int,
            accessUnit: ByteArray,
        ): ByteArray =
            ByteBuffer.allocate(HEADER_BYTES + accessUnit.size)
                .order(ByteOrder.BIG_ENDIAN)
                .put(flags.toByte())
                .putLong(captureTimestampUs)
                .putInt(seq)
                .put(accessUnit)
                .array()
    }
}

/** TOUCH phases, PROTOCOL.md §6.1. */
object TouchPhase {
    const val BEGAN: Byte = 0
    const val MOVED: Byte = 1
    const val ENDED: Byte = 2
    const val CANCELLED: Byte = 3
}

/** TOUCH tool kinds, PROTOCOL.md §6.1. */
object TouchTool {
    const val FINGER: Byte = 0
    const val STYLUS: Byte = 1
}

/** SCROLL phases, PROTOCOL.md §6.2. */
object ScrollPhase {
    const val BEGIN: Byte = 0
    const val CHANGED: Byte = 1
    const val ENDED: Byte = 2
}

/** POINTER kinds and buttons, PROTOCOL.md §6.4. */
object PointerKind {
    const val MOVE: Byte = 0
    const val DOWN: Byte = 1
    const val UP: Byte = 2
}

object PointerButton {
    const val LEFT: Byte = 0
    const val RIGHT: Byte = 1
    const val MIDDLE: Byte = 2
}

/**
 * One pointer inside a TOUCH frame. `x`/`y` are normalised to `[0,1]` over the
 * *encoded video frame*, origin top-left (PROTOCOL.md §5.1).
 */
data class TouchPointer(
    val pointerId: Int,
    val tool: Byte,
    val x: Float,
    val y: Float,
    val pressure: Float,
    val tiltX: Float,
    val tiltY: Float,
    val azimuth: Float,
) {
    companion object {
        /** `[u32 id][u8 tool][f32 x][f32 y][f32 pressure][f32 tiltX][f32 tiltY][f32 azimuth]` */
        const val BYTES = 4 + 1 + 6 * 4
    }
}

/** Encoders and decoders for the binary input payloads (PROTOCOL.md §6). */
object InputCodec {
    fun encodeTouch(phase: Byte, pointers: List<TouchPointer>): ByteArray {
        if (pointers.size > 255) throw ProtocolException("TOUCH carries at most 255 pointers")
        val buffer =
            ByteBuffer.allocate(2 + pointers.size * TouchPointer.BYTES)
                .order(ByteOrder.BIG_ENDIAN)
        buffer.put(phase)
        buffer.put(pointers.size.toByte())
        for (p in pointers) {
            buffer.putInt(p.pointerId)
            buffer.put(p.tool)
            buffer.putFloat(p.x)
            buffer.putFloat(p.y)
            buffer.putFloat(p.pressure)
            buffer.putFloat(p.tiltX)
            buffer.putFloat(p.tiltY)
            buffer.putFloat(p.azimuth)
        }
        return buffer.array()
    }

    fun decodeTouch(payload: ByteArray): Pair<Byte, List<TouchPointer>> {
        if (payload.size < 2) throw ProtocolException("TOUCH payload is too short")
        val buffer = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val phase = buffer.get()
        val count = buffer.get().toInt() and 0xFF
        if (payload.size != 2 + count * TouchPointer.BYTES) {
            throw ProtocolException("TOUCH payload of ${payload.size} bytes does not hold $count pointers")
        }
        val pointers =
            (0 until count).map {
                TouchPointer(
                    pointerId = buffer.int,
                    tool = buffer.get(),
                    x = buffer.float,
                    y = buffer.float,
                    pressure = buffer.float,
                    tiltX = buffer.float,
                    tiltY = buffer.float,
                    azimuth = buffer.float,
                )
            }
        return phase to pointers
    }

    /** `[f32 x][f32 y][f32 dx][f32 dy][u8 phase]` */
    fun encodeScroll(x: Float, y: Float, dx: Float, dy: Float, phase: Byte): ByteArray =
        ByteBuffer.allocate(17)
            .order(ByteOrder.BIG_ENDIAN)
            .putFloat(x)
            .putFloat(y)
            .putFloat(dx)
            .putFloat(dy)
            .put(phase)
            .array()

    fun decodeScroll(payload: ByteArray): FloatArray {
        if (payload.size != 17) throw ProtocolException("SCROLL payload must be 17 bytes")
        val buffer = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        return floatArrayOf(
            buffer.float,
            buffer.float,
            buffer.float,
            buffer.float,
            buffer.get().toFloat(),
        )
    }

    /** `[u8 kind][u8 button][f32 x][f32 y]` */
    fun encodePointer(kind: Byte, button: Byte, x: Float, y: Float): ByteArray =
        ByteBuffer.allocate(10)
            .order(ByteOrder.BIG_ENDIAN)
            .put(kind)
            .put(button)
            .putFloat(x)
            .putFloat(y)
            .array()

    fun decodePointer(payload: ByteArray): Array<Any> {
        if (payload.size != 10) throw ProtocolException("POINTER payload must be 10 bytes")
        val buffer = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        return arrayOf(buffer.get(), buffer.get(), buffer.float, buffer.float)
    }

    /** PING is `[u64 t_send_us]`. */
    fun encodePing(sendMicros: Long): ByteArray =
        ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(sendMicros).array()

    fun decodePing(payload: ByteArray): Long {
        if (payload.size < 8) throw ProtocolException("PING payload must be 8 bytes")
        return ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN).long
    }

    /** PONG is `[u64 t_echo_us][u64 t_recv_us]`. */
    fun encodePong(echoMicros: Long, receiveMicros: Long): ByteArray =
        ByteBuffer.allocate(16)
            .order(ByteOrder.BIG_ENDIAN)
            .putLong(echoMicros)
            .putLong(receiveMicros)
            .array()

    fun decodePong(payload: ByteArray): Pair<Long, Long> {
        if (payload.size < 16) throw ProtocolException("PONG payload must be 16 bytes")
        val buffer = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        return buffer.long to buffer.long
    }
}
