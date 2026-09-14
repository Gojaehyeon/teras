package app.teras.receiver.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The binary input and video layouts of PROTOCOL.md §4 and §6. */
class BinaryPayloadsTest {
    @Test
    fun `touch frames round trip with every pointer field`() {
        val pointers =
            listOf(
                TouchPointer(7, TouchTool.FINGER, 0.25f, 0.5f, 0.8f, 0f, 0f, 0f),
                TouchPointer(9, TouchTool.STYLUS, 0.75f, 0.125f, 0.42f, 0.1f, -0.2f, 1.4f),
            )
        val encoded = InputCodec.encodeTouch(TouchPhase.MOVED, pointers)

        assertEquals(2 + 2 * TouchPointer.BYTES, encoded.size)
        assertEquals(TouchPhase.MOVED, encoded[0])
        assertEquals(2, encoded[1].toInt())

        val (phase, decoded) = InputCodec.decodeTouch(encoded)
        assertEquals(TouchPhase.MOVED, phase)
        assertEquals(pointers, decoded)
    }

    @Test
    fun `an empty touch frame is two bytes`() {
        val encoded = InputCodec.encodeTouch(TouchPhase.CANCELLED, emptyList())
        assertArrayEquals(byteArrayOf(TouchPhase.CANCELLED, 0), encoded)
        assertTrue(InputCodec.decodeTouch(encoded).second.isEmpty())
    }

    @Test
    fun `a touch frame whose pointer count disagrees with its length is rejected`() {
        val encoded = InputCodec.encodeTouch(TouchPhase.BEGAN, listOf(TouchPointer(1, 0, 0f, 0f, 0f, 0f, 0f, 0f)))
        val truncated = encoded.copyOfRange(0, encoded.size - 4)
        assertThrows(ProtocolException::class.java) { InputCodec.decodeTouch(truncated) }
    }

    @Test
    fun `scroll is seventeen bytes in field order`() {
        val encoded = InputCodec.encodeScroll(0.5f, 0.25f, -3f, 12.5f, ScrollPhase.CHANGED)
        assertEquals(17, encoded.size)
        val decoded = InputCodec.decodeScroll(encoded)
        assertEquals(0.5f, decoded[0], 0f)
        assertEquals(0.25f, decoded[1], 0f)
        assertEquals(-3f, decoded[2], 0f)
        assertEquals(12.5f, decoded[3], 0f)
        assertEquals(ScrollPhase.CHANGED.toFloat(), decoded[4], 0f)
    }

    @Test
    fun `pointer is ten bytes in field order`() {
        val encoded = InputCodec.encodePointer(PointerKind.DOWN, PointerButton.RIGHT, 0.1f, 0.9f)
        assertEquals(10, encoded.size)
        val decoded = InputCodec.decodePointer(encoded)
        assertEquals(PointerKind.DOWN, decoded[0])
        assertEquals(PointerButton.RIGHT, decoded[1])
        assertEquals(0.1f, decoded[2] as Float, 0f)
        assertEquals(0.9f, decoded[3] as Float, 0f)
    }

    @Test
    fun `ping and pong carry big-endian microsecond stamps`() {
        val ping = InputCodec.encodePing(0x0102030405060708L)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8), ping)
        assertEquals(0x0102030405060708L, InputCodec.decodePing(ping))

        val pong = InputCodec.encodePong(11L, 22L)
        assertEquals(16, pong.size)
        assertEquals(11L to 22L, InputCodec.decodePong(pong))
    }

    @Test
    fun `video frames round trip through their thirteen byte header`() {
        val accessUnit = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x65, 1, 2, 3)
        val payload =
            VideoFrame.encode(
                flags = VideoFrame.FLAG_KEYFRAME or VideoFrame.FLAG_PARAMETER_SETS,
                captureTimestampUs = 1_234_567_890L,
                seq = 42,
                accessUnit = accessUnit,
            )

        val frame = VideoFrame.parse(payload)
        assertTrue(frame.isKeyframe)
        assertTrue(frame.hasParameterSets)
        assertEquals(false, frame.isDiscontinuity)
        assertEquals(1_234_567_890L, frame.captureTimestampUs)
        assertEquals(42, frame.seq)
        assertEquals(accessUnit.size, frame.accessUnitLength)
        assertArrayEquals(
            accessUnit,
            frame.accessUnit.copyOfRange(
                frame.accessUnitOffset,
                frame.accessUnitOffset + frame.accessUnitLength,
            ),
        )
    }

    @Test
    fun `the discontinuity flag is bit two`() {
        val payload = VideoFrame.encode(VideoFrame.FLAG_DISCONTINUITY, 0, 0, ByteArray(1))
        assertTrue(VideoFrame.parse(payload).isDiscontinuity)
    }

    @Test
    fun `a video frame shorter than its header is rejected`() {
        assertThrows(ProtocolException::class.java) { VideoFrame.parse(ByteArray(12)) }
    }
}
