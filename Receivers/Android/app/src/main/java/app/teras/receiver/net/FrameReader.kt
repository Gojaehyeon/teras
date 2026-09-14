package app.teras.receiver.net

import java.io.EOFException
import java.io.InputStream

/**
 * Reassembles `[u32 length][u8 type][payload]` frames from a byte stream
 * (PROTOCOL.md §2). TCP gives no message boundaries, so every read is filled
 * completely before a frame is handed out.
 */
class FrameReader(private val input: InputStream) {
    private val header = ByteArray(4)

    /**
     * Reads exactly one frame, blocking until it is complete.
     *
     * @throws EOFException when the peer closed the stream cleanly between frames.
     * @throws ProtocolException when the length prefix is outside `1 … 16 MiB`
     *   or the stream ends mid-frame.
     */
    fun readFrame(): Frame {
        readFully(header, 0, 4, allowCleanEof = true)
        val length =
            ((header[0].toInt() and 0xFF) shl 24) or
                ((header[1].toInt() and 0xFF) shl 16) or
                ((header[2].toInt() and 0xFF) shl 8) or
                (header[3].toInt() and 0xFF)

        if (length < Protocol.MIN_LENGTH || length > Protocol.MAX_LENGTH) {
            throw ProtocolException("frame length $length outside 1..${Protocol.MAX_LENGTH}")
        }

        val body = ByteArray(length)
        readFully(body, 0, length, allowCleanEof = false)
        return Frame(body[0], body.copyOfRange(1, length))
    }

    private fun readFully(dest: ByteArray, offset: Int, length: Int, allowCleanEof: Boolean) {
        var read = 0
        while (read < length) {
            val n = input.read(dest, offset + read, length - read)
            if (n < 0) {
                if (read == 0 && allowCleanEof) throw EOFException("peer closed the connection")
                throw ProtocolException("stream ended after $read of $length bytes")
            }
            read += n
        }
    }
}
