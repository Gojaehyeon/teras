package app.teras.receiver.net

import java.io.OutputStream

/**
 * Serialises frames onto a stream. Writes are synchronised because the video,
 * input, heartbeat and stats paths all share one connection.
 */
class FrameWriter(private val output: OutputStream) {
    private val lock = Any()

    fun writeFrame(type: Byte, payload: ByteArray) {
        if (payload.size + 1 > Protocol.MAX_LENGTH) {
            throw ProtocolException("frame of ${payload.size + 1} bytes exceeds the 16 MiB limit")
        }
        val length = payload.size + 1
        val buffer = ByteArray(4 + length)
        buffer[0] = ((length ushr 24) and 0xFF).toByte()
        buffer[1] = ((length ushr 16) and 0xFF).toByte()
        buffer[2] = ((length ushr 8) and 0xFF).toByte()
        buffer[3] = (length and 0xFF).toByte()
        buffer[4] = type
        System.arraycopy(payload, 0, buffer, 5, payload.size)

        synchronized(lock) {
            output.write(buffer)
            output.flush()
        }
    }

    fun writeFrame(frame: Frame) = writeFrame(frame.type, frame.payload)
}
