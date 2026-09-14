package app.tandem.receiver.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** The ENC envelope of PROTOCOL.md §2.1. */
class SessionCipherTest {
    private val secret = ByteArray(32) { 0x03 }
    private val hostNonce = ByteArray(16) { 0x01 }
    private val deviceNonce = ByteArray(16) { 0x02 }

    private fun hostCipher() = SessionCipher.forHost(secret, hostNonce, deviceNonce)

    private fun receiverCipher() = SessionCipher.forReceiver(secret, hostNonce, deviceNonce)

    @Test
    fun `the receiver opens what the host sealed, in both directions`() {
        val host = hostCipher()
        val receiver = receiverCipher()

        val (type, payload) = receiver.open(host.seal(0x30, ByteArray(8)))
        assertEquals(0x30.toByte(), type)
        assertArrayEquals(ByteArray(8), payload)

        val (backType, backPayload) = host.open(receiver.seal(0x32, "{}".toByteArray()))
        assertEquals(0x32.toByte(), backType)
        assertArrayEquals("{}".toByteArray(), backPayload)
    }

    @Test
    fun `the counter is the first eight bytes and starts at zero`() {
        val host = hostCipher()
        val first = host.seal(0x30, ByteArray(8))
        val second = host.seal(0x30, ByteArray(8))

        assertArrayEquals(ByteArray(8), first.copyOfRange(0, 8))
        assertArrayEquals(byteArrayOf(0, 0, 0, 0, 0, 0, 0, 1), second.copyOfRange(0, 8))
    }

    @Test
    fun `the envelope is counter plus ciphertext plus a sixteen byte tag`() {
        val sealed = hostCipher().seal(0x30, ByteArray(8))
        assertEquals(8 + 9 + 16, sealed.size)
    }

    @Test
    fun `a replayed counter is rejected`() {
        val host = hostCipher()
        val receiver = receiverCipher()
        val first = host.seal(0x30, ByteArray(8))
        receiver.open(first)
        assertThrows(SessionCipherException::class.java) { receiver.open(first) }
    }

    @Test
    fun `a counter that goes backwards is rejected`() {
        val host = hostCipher()
        val receiver = receiverCipher()
        val first = host.seal(0x30, ByteArray(8))
        val second = host.seal(0x30, ByteArray(8))

        receiver.open(second)
        assertThrows(SessionCipherException::class.java) { receiver.open(first) }
    }

    @Test
    fun `a gap in counters is accepted because frames may be dropped upstream`() {
        val host = hostCipher()
        val receiver = receiverCipher()
        host.seal(0x30, ByteArray(8))
        host.seal(0x30, ByteArray(8))
        val third = host.seal(0x12, byteArrayOf(9))

        val (type, payload) = receiver.open(third)
        assertEquals(0x12.toByte(), type)
        assertArrayEquals(byteArrayOf(9), payload)
    }

    @Test
    fun `a tampered tag is rejected and does not burn the counter`() {
        val host = hostCipher()
        val receiver = receiverCipher()
        val sealed = host.seal(0x30, ByteArray(8))
        val tampered = sealed.copyOf().also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() }

        assertThrows(SessionCipherException::class.java) { receiver.open(tampered) }
        // The genuine frame with the same counter still opens.
        assertEquals(0x30.toByte(), receiver.open(sealed).first)
    }

    @Test
    fun `the aad is bound to the envelope type`() {
        // Re-sealing with a different AAD must not verify, which is what stops a
        // frame being lifted out of the envelope and replayed as another type.
        val host = hostCipher()
        val receiver = receiverCipher()
        val sealed = host.seal(0x30, ByteArray(8))
        val truncated = sealed.copyOfRange(0, sealed.size - 1)
        assertThrows(SessionCipherException::class.java) { receiver.open(truncated) }
    }

    @Test
    fun `a short envelope is rejected`() {
        assertThrows(SessionCipherException::class.java) { receiverCipher().open(ByteArray(20)) }
    }

    @Test
    fun `directions do not share a key`() {
        val host = hostCipher()
        val other = SessionCipher.forHost(secret, hostNonce, deviceNonce)
        // A host-sealed frame must not open with a host-oriented cipher, which
        // receives on key_r2h.
        assertThrows(SessionCipherException::class.java) { other.open(host.seal(0x30, ByteArray(8))) }
    }
}
