package app.teras.receiver.crypto

import java.nio.ByteBuffer
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** A frame that failed to decrypt, replayed, or arrived out of order. */
class SessionCipherException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * The encrypted envelope, PROTOCOL.md §2.1 — type `0x7F`, payload
 * `[u64 counter][ciphertext][16-byte GCM tag]`.
 *
 * One instance holds both directions. Each direction has its own key and its
 * own counter starting at 0; the nonce is `[u32 0][u64 counter]` big-endian and
 * the additional authenticated data is the single byte `0x7F`. An inbound
 * counter that does not strictly increase is a protocol error and the caller
 * must close the connection.
 */
class SessionCipher(
    private val sendKey: ByteArray,
    private val receiveKey: ByteArray,
) {
    private var sendCounter: Long = 0
    private var lastReceivedCounter: Long = 0
    private var receivedAny: Boolean = false

    init {
        require(sendKey.size == 32 && receiveKey.size == 32) { "session keys must be 32 bytes" }
    }

    /**
     * Wraps `[type][payload]` into the ENC payload. Returns the bytes that
     * follow the `0x7F` type byte on the wire.
     */
    @Synchronized
    fun seal(innerType: Byte, innerPayload: ByteArray): ByteArray {
        val counter = sendCounter
        val plaintext = ByteArray(1 + innerPayload.size)
        plaintext[0] = innerType
        System.arraycopy(innerPayload, 0, plaintext, 1, innerPayload.size)

        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(sendKey, "AES"),
            GCMParameterSpec(TAG_BITS, nonceFor(counter)),
        )
        cipher.updateAAD(AAD)
        val sealed = cipher.doFinal(plaintext)

        val out = ByteArray(8 + sealed.size)
        writeCounter(out, counter)
        System.arraycopy(sealed, 0, out, 8, sealed.size)
        sendCounter = counter + 1
        return out
    }

    /** Unwraps an ENC payload back into `[type][payload]`. */
    @Synchronized
    fun open(encPayload: ByteArray): Pair<Byte, ByteArray> {
        if (encPayload.size < 8 + TAG_BYTES + 1) {
            throw SessionCipherException("ENC frame too short: ${encPayload.size} bytes")
        }
        val counter = ByteBuffer.wrap(encPayload, 0, 8).long
        if (receivedAny && java.lang.Long.compareUnsigned(counter, lastReceivedCounter) <= 0) {
            throw SessionCipherException(
                "ENC counter not strictly increasing: got $counter after $lastReceivedCounter",
            )
        }

        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(receiveKey, "AES"),
            GCMParameterSpec(TAG_BITS, nonceFor(counter)),
        )
        cipher.updateAAD(AAD)
        val plaintext =
            try {
                cipher.doFinal(encPayload, 8, encPayload.size - 8)
            } catch (e: AEADBadTagException) {
                throw SessionCipherException("ENC authentication failed", e)
            }
        if (plaintext.isEmpty()) throw SessionCipherException("ENC plaintext is empty")

        // Only commit the counter once the tag has verified, so a forged frame
        // cannot burn counter values and wedge the session.
        lastReceivedCounter = counter
        receivedAny = true
        return plaintext[0] to plaintext.copyOfRange(1, plaintext.size)
    }

    private fun nonceFor(counter: Long): ByteArray {
        val nonce = ByteArray(NONCE_BYTES)
        for (i in 0 until 8) {
            nonce[4 + i] = ((counter ushr ((7 - i) * 8)) and 0xFF).toByte()
        }
        return nonce
    }

    private fun writeCounter(out: ByteArray, counter: Long) {
        for (i in 0 until 8) {
            out[i] = ((counter ushr ((7 - i) * 8)) and 0xFF).toByte()
        }
    }

    companion object {
        const val NONCE_BYTES = 12
        const val TAG_BITS = 128
        const val TAG_BYTES = TAG_BITS / 8
        private const val TRANSFORM = "AES/GCM/NoPadding"

        /** AAD is the envelope type byte itself. */
        private val AAD = byteArrayOf(0x7F)

        private val INFO_H2R = "teras-v1-h2r".toByteArray(Charsets.US_ASCII)
        private val INFO_R2H = "teras-v1-r2h".toByteArray(Charsets.US_ASCII)

        fun hostToReceiverKey(secret: ByteArray, hostNonce: ByteArray, deviceNonce: ByteArray): ByteArray =
            CryptoPrimitives.hkdf(secret, PairingCrypto.handshakeSalt(hostNonce, deviceNonce), INFO_H2R, 32)

        fun receiverToHostKey(secret: ByteArray, hostNonce: ByteArray, deviceNonce: ByteArray): ByteArray =
            CryptoPrimitives.hkdf(secret, PairingCrypto.handshakeSalt(hostNonce, deviceNonce), INFO_R2H, 32)

        /**
         * The receiver's view: it sends on `key_r2h` and receives on `key_h2r`.
         */
        fun forReceiver(secret: ByteArray, hostNonce: ByteArray, deviceNonce: ByteArray): SessionCipher =
            SessionCipher(
                sendKey = receiverToHostKey(secret, hostNonce, deviceNonce),
                receiveKey = hostToReceiverKey(secret, hostNonce, deviceNonce),
            )

        /** The mirror image, used by tests to stand in for the Mac host. */
        fun forHost(secret: ByteArray, hostNonce: ByteArray, deviceNonce: ByteArray): SessionCipher =
            SessionCipher(
                sendKey = hostToReceiverKey(secret, hostNonce, deviceNonce),
                receiveKey = receiverToHostKey(secret, hostNonce, deviceNonce),
            )
    }
}
