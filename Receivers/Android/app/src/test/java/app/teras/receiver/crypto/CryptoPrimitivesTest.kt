package app.teras.receiver.crypto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Known-answer tests for the primitives the Mac host must match. These are
 * published vectors, not values this implementation produced, so they catch a
 * wrong construction rather than merely a changed one.
 */
class CryptoPrimitivesTest {
    @Test
    fun `sha256 matches the FIPS 180-2 abc vector`() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            CryptoPrimitives.hex(CryptoPrimitives.sha256("abc".toByteArray(Charsets.US_ASCII))),
        )
    }

    @Test
    fun `hmac sha256 matches RFC 4231 test case 1`() {
        val key = ByteArray(20) { 0x0b }
        val mac = CryptoPrimitives.hmacSha256(key, "Hi There".toByteArray(Charsets.US_ASCII))
        assertEquals(
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
            CryptoPrimitives.hex(mac),
        )
    }

    @Test
    fun `hmac sha256 concatenates its parts`() {
        val key = ByteArray(32) { 0x05 }
        val split = CryptoPrimitives.hmacSha256(key, byteArrayOf(1, 2), byteArrayOf(3, 4))
        val whole = CryptoPrimitives.hmacSha256(key, byteArrayOf(1, 2, 3, 4))
        assertEquals(CryptoPrimitives.hex(whole), CryptoPrimitives.hex(split))
    }

    @Test
    fun `hkdf matches RFC 5869 test case 1`() {
        val ikm = ByteArray(22) { 0x0b }
        val salt = CryptoPrimitives.unhex("000102030405060708090a0b0c")
        val info = CryptoPrimitives.unhex("f0f1f2f3f4f5f6f7f8f9")

        assertEquals(
            "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5",
            CryptoPrimitives.hex(CryptoPrimitives.hkdfExtract(salt, ikm)),
        )
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf" +
                "34007208d5b887185865",
            CryptoPrimitives.hex(CryptoPrimitives.hkdf(ikm, salt, info, 42)),
        )
    }

    @Test
    fun `hkdf matches RFC 5869 test case 3 with empty salt and info`() {
        val ikm = ByteArray(22) { 0x0b }
        assertEquals(
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d" +
                "9d201395faa4b61a96c8",
            CryptoPrimitives.hex(CryptoPrimitives.hkdf(ikm, ByteArray(0), ByteArray(0), 42)),
        )
    }

    @Test
    fun `aes 256 gcm matches the GCM specification test cases`() {
        // McGrew & Viega test case 13: empty plaintext.
        assertEquals(
            "530f8afbc74536b9a963b4f1c4cb738b",
            CryptoPrimitives.hex(gcm(ByteArray(32), ByteArray(12), ByteArray(0))),
        )
        // Test case 14: one all-zero block.
        assertEquals(
            "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919",
            CryptoPrimitives.hex(gcm(ByteArray(32), ByteArray(12), ByteArray(16))),
        )
    }

    private fun gcm(key: ByteArray, nonce: ByteArray, plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return cipher.doFinal(plaintext)
    }

    @Test
    fun `constant time equals compares content and length`() {
        assertTrue(CryptoPrimitives.constantTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2, 3)))
        assertFalse(CryptoPrimitives.constantTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2, 4)))
        assertFalse(CryptoPrimitives.constantTimeEquals(byteArrayOf(1, 2), byteArrayOf(1, 2, 3)))
    }

    @Test
    fun `hex round trips`() {
        val bytes = ByteArray(64) { (it * 7).toByte() }
        assertEquals(
            CryptoPrimitives.hex(bytes),
            CryptoPrimitives.hex(CryptoPrimitives.unhex(CryptoPrimitives.hex(bytes))),
        )
    }
}
