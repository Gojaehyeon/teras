package app.teras.receiver.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream

/** Framing round trips and the length-prefix rules of PROTOCOL.md §2. */
class FrameCodecTest {
    @Test
    fun `frames round trip through the writer and reader`() {
        val out = ByteArrayOutputStream()
        val writer = FrameWriter(out)
        val sent =
            listOf(
                Frame(MessageType.HELLO, """{"pv":1}""".toByteArray()),
                Frame(MessageType.KEYFRAME_REQUEST, ByteArray(0)),
                Frame(MessageType.VIDEO, ByteArray(4096) { it.toByte() }),
                Frame(MessageType.ENC, ByteArray(33) { (255 - it).toByte() }),
            )
        sent.forEach { writer.writeFrame(it) }

        val reader = FrameReader(ByteArrayInputStream(out.toByteArray()))
        sent.forEach { assertEquals(it, reader.readFrame()) }
        assertThrows(EOFException::class.java) { reader.readFrame() }
    }

    @Test
    fun `the wire layout is a big-endian length then the type byte`() {
        val out = ByteArrayOutputStream()
        FrameWriter(out).writeFrame(MessageType.PING, ByteArray(8))
        val bytes = out.toByteArray()

        assertEquals(13, bytes.size)
        // length = 1 + 8 payload bytes
        assertArrayEquals(byteArrayOf(0, 0, 0, 9), bytes.copyOfRange(0, 4))
        assertEquals(MessageType.PING, bytes[4])
    }

    @Test
    fun `reassembly survives a stream that yields one byte at a time`() {
        val out = ByteArrayOutputStream()
        val payload = ByteArray(1000) { (it % 251).toByte() }
        FrameWriter(out).writeFrame(MessageType.STATS, payload)

        val trickle =
            object : InputStream() {
                private val data = out.toByteArray()
                private var index = 0

                override fun read(): Int = if (index < data.size) data[index++].toInt() and 0xFF else -1

                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    if (index >= data.size) return -1
                    b[off] = data[index++]
                    return 1
                }
            }

        val frame = FrameReader(trickle).readFrame()
        assertEquals(MessageType.STATS, frame.type)
        assertArrayEquals(payload, frame.payload)
    }

    @Test
    fun `a zero length prefix is a protocol error`() {
        val reader = FrameReader(ByteArrayInputStream(byteArrayOf(0, 0, 0, 0)))
        assertThrows(ProtocolException::class.java) { reader.readFrame() }
    }

    @Test
    fun `a length above 16 MiB is a protocol error`() {
        val tooBig = Protocol.MAX_LENGTH + 1
        val header =
            byteArrayOf(
                (tooBig ushr 24).toByte(),
                (tooBig ushr 16).toByte(),
                (tooBig ushr 8).toByte(),
                tooBig.toByte(),
            )
        val reader = FrameReader(ByteArrayInputStream(header))
        assertThrows(ProtocolException::class.java) { reader.readFrame() }
    }

    @Test
    fun `a truncated body is a protocol error rather than a short frame`() {
        val reader = FrameReader(ByteArrayInputStream(byteArrayOf(0, 0, 0, 10, MessageType.PING, 1, 2)))
        assertThrows(ProtocolException::class.java) { reader.readFrame() }
    }
}
