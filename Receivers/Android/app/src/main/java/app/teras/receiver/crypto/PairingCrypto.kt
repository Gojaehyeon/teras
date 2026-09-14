package app.teras.receiver.crypto

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * PIN pairing and mutual authentication, PROTOCOL.md §3.3.
 *
 * Every byte string below is spelled out explicitly because the Mac host has to
 * reproduce it exactly:
 *
 *  * `pinKey   = SHA256(utf8(pin) ‖ utf8(deviceId) ‖ utf8(hostId))`
 *  * `pairProof = HMAC-SHA256(pinKey,  utf8("pair")     ‖ hostNonce ‖ deviceNonce)`
 *  * `authProof = HMAC-SHA256(secret,  utf8("auth")     ‖ hostNonce ‖ deviceNonce)`
 *  * `authAck   = HMAC-SHA256(secret,  utf8("auth-ack") ‖ hostNonce ‖ deviceNonce)`
 *
 * The labels are raw ASCII with no separator and no length prefix; the nonces
 * are the raw 16 decoded bytes, not their Base64 spelling. The identifiers are
 * the UUID strings exactly as they travel in HELLO/HELLO_ACK — byte-identical,
 * so case matters.
 */
object PairingCrypto {
    const val NONCE_BYTES = 16
    const val SECRET_BYTES = 32

    private val LABEL_PAIR = "pair".toByteArray(Charsets.US_ASCII)
    private val LABEL_AUTH = "auth".toByteArray(Charsets.US_ASCII)
    private val LABEL_AUTH_ACK = "auth-ack".toByteArray(Charsets.US_ASCII)
    private val INFO_PAIRBOX = "teras-v1-pairbox".toByteArray(Charsets.US_ASCII)

    private val random = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    fun randomNonce(): ByteArray = randomBytes(NONCE_BYTES)

    fun randomSecret(): ByteArray = randomBytes(SECRET_BYTES)

    /** A uniformly distributed 6-digit PIN, leading zeros kept. */
    fun randomPin(): String = String.format("%06d", random.nextInt(1_000_000))

    fun pinKey(pin: String, deviceId: String, hostId: String): ByteArray =
        CryptoPrimitives.sha256(
            pin.toByteArray(Charsets.UTF_8),
            deviceId.toByteArray(Charsets.UTF_8),
            hostId.toByteArray(Charsets.UTF_8),
        )

    fun pairProof(pinKey: ByteArray, hostNonce: ByteArray, deviceNonce: ByteArray): ByteArray =
        CryptoPrimitives.hmacSha256(pinKey, LABEL_PAIR, hostNonce, deviceNonce)

    fun authProof(secret: ByteArray, hostNonce: ByteArray, deviceNonce: ByteArray): ByteArray =
        CryptoPrimitives.hmacSha256(secret, LABEL_AUTH, hostNonce, deviceNonce)

    fun authAckProof(secret: ByteArray, hostNonce: ByteArray, deviceNonce: ByteArray): ByteArray =
        CryptoPrimitives.hmacSha256(secret, LABEL_AUTH_ACK, hostNonce, deviceNonce)

    /** `salt = hostNonce ‖ deviceNonce`, shared by the pair box and the session keys. */
    fun handshakeSalt(hostNonce: ByteArray, deviceNonce: ByteArray): ByteArray =
        hostNonce + deviceNonce

    /**
     * `PAIR_OK.box` = AES-256-GCM(HKDF(pinKey, salt, "teras-v1-pairbox", 32),
     * nonce = 12 zero bytes, plaintext = secret), returned as ciphertext ‖ tag.
     *
     * A fixed all-zero nonce is safe only because the key is single-use: it is
     * derived from a fresh nonce pair that is never reused for a second box.
     */
    fun sealPairBox(
        pinKey: ByteArray,
        hostNonce: ByteArray,
        deviceNonce: ByteArray,
        secret: ByteArray,
    ): ByteArray {
        val key = pairBoxKey(pinKey, hostNonce, deviceNonce)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(SessionCipher.TAG_BITS, ByteArray(SessionCipher.NONCE_BYTES)),
        )
        return cipher.doFinal(secret)
    }

    /** The host side of [sealPairBox]; kept here so the two stay in step. */
    fun openPairBox(
        pinKey: ByteArray,
        hostNonce: ByteArray,
        deviceNonce: ByteArray,
        box: ByteArray,
    ): ByteArray {
        val key = pairBoxKey(pinKey, hostNonce, deviceNonce)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(SessionCipher.TAG_BITS, ByteArray(SessionCipher.NONCE_BYTES)),
        )
        return cipher.doFinal(box)
    }

    fun pairBoxKey(pinKey: ByteArray, hostNonce: ByteArray, deviceNonce: ByteArray): ByteArray =
        CryptoPrimitives.hkdf(pinKey, handshakeSalt(hostNonce, deviceNonce), INFO_PAIRBOX, 32)
}
