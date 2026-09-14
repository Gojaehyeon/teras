package app.teras.receiver.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** PROTOCOL.md §3.3, checked structurally rather than only by round trip. */
class PairingCryptoTest {
    private val pin = "123456"
    private val hostId = "11111111-1111-1111-1111-111111111111"
    private val deviceId = "22222222-2222-2222-2222-222222222222"
    private val hostNonce = ByteArray(16) { 0x01 }
    private val deviceNonce = ByteArray(16) { 0x02 }
    private val secret = ByteArray(32) { 0x03 }

    @Test
    fun `pinKey is sha256 over pin then deviceId then hostId`() {
        val expected =
            CryptoPrimitives.sha256(
                (pin + deviceId + hostId).toByteArray(Charsets.UTF_8),
            )
        assertArrayEquals(expected, PairingCrypto.pinKey(pin, deviceId, hostId))
    }

    @Test
    fun `the identifier order in pinKey matters`() {
        assertNotEquals(
            CryptoPrimitives.hex(PairingCrypto.pinKey(pin, deviceId, hostId)),
            CryptoPrimitives.hex(PairingCrypto.pinKey(pin, hostId, deviceId)),
        )
    }

    @Test
    fun `proof labels are raw ascii followed by the raw nonces`() {
        val pinKey = PairingCrypto.pinKey(pin, deviceId, hostId)
        assertArrayEquals(
            CryptoPrimitives.hmacSha256(
                pinKey,
                "pair".toByteArray(Charsets.US_ASCII) + hostNonce + deviceNonce,
            ),
            PairingCrypto.pairProof(pinKey, hostNonce, deviceNonce),
        )
        assertArrayEquals(
            CryptoPrimitives.hmacSha256(
                secret,
                "auth".toByteArray(Charsets.US_ASCII) + hostNonce + deviceNonce,
            ),
            PairingCrypto.authProof(secret, hostNonce, deviceNonce),
        )
        assertArrayEquals(
            CryptoPrimitives.hmacSha256(
                secret,
                "auth-ack".toByteArray(Charsets.US_ASCII) + hostNonce + deviceNonce,
            ),
            PairingCrypto.authAckProof(secret, hostNonce, deviceNonce),
        )
    }

    @Test
    fun `auth and auth-ack proofs differ`() {
        assertNotEquals(
            CryptoPrimitives.hex(PairingCrypto.authProof(secret, hostNonce, deviceNonce)),
            CryptoPrimitives.hex(PairingCrypto.authAckProof(secret, hostNonce, deviceNonce)),
        )
    }

    @Test
    fun `the nonce order in the handshake salt matters`() {
        assertNotEquals(
            CryptoPrimitives.hex(PairingCrypto.handshakeSalt(hostNonce, deviceNonce)),
            CryptoPrimitives.hex(PairingCrypto.handshakeSalt(deviceNonce, hostNonce)),
        )
    }

    @Test
    fun `the pair box opens with the same pinKey`() {
        val pinKey = PairingCrypto.pinKey(pin, deviceId, hostId)
        val box = PairingCrypto.sealPairBox(pinKey, hostNonce, deviceNonce, secret)

        // ciphertext of a 32-byte secret plus a 16-byte tag
        assertEquals(48, box.size)
        assertArrayEquals(secret, PairingCrypto.openPairBox(pinKey, hostNonce, deviceNonce, box))
    }

    @Test
    fun `a wrong pin cannot open the pair box`() {
        val box =
            PairingCrypto.sealPairBox(
                PairingCrypto.pinKey(pin, deviceId, hostId),
                hostNonce,
                deviceNonce,
                secret,
            )
        val wrongKey = PairingCrypto.pinKey("000000", deviceId, hostId)
        val failed =
            try {
                PairingCrypto.openPairBox(wrongKey, hostNonce, deviceNonce, box)
                false
            } catch (_: Exception) {
                true
            }
        assertTrue("a box opened under the wrong PIN", failed)
    }

    @Test
    fun `generated pins are six digits`() {
        repeat(200) {
            val generated = PairingCrypto.randomPin()
            assertEquals(6, generated.length)
            assertTrue(generated.all { it.isDigit() })
        }
    }

    @Test
    fun `session keys differ by direction`() {
        val h2r = SessionCipher.hostToReceiverKey(secret, hostNonce, deviceNonce)
        val r2h = SessionCipher.receiverToHostKey(secret, hostNonce, deviceNonce)
        assertEquals(32, h2r.size)
        assertEquals(32, r2h.size)
        assertNotEquals(CryptoPrimitives.hex(h2r), CryptoPrimitives.hex(r2h))
    }
}
