package app.tandem.receiver.crypto

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The hash/MAC/KDF primitives the Tandem wire protocol is built on
 * (PROTOCOL.md §2.1 and §3.3). Everything here is deliberately free of Android
 * APIs so the JVM unit tests exercise exactly the code that runs on device.
 */
object CryptoPrimitives {
    const val HMAC_SHA256 = "HmacSHA256"

    fun sha256(vararg parts: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        for (part in parts) digest.update(part)
        return digest.digest()
    }

    fun hmacSha256(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance(HMAC_SHA256)
        // An all-zero-length key is not a legal SecretKeySpec; the protocol
        // never produces one, but fail loudly rather than silently substituting.
        require(key.isNotEmpty()) { "HMAC key must not be empty" }
        mac.init(SecretKeySpec(key, HMAC_SHA256))
        for (part in parts) mac.update(part)
        return mac.doFinal()
    }

    /** RFC 5869 HKDF-Extract. */
    fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val effectiveSalt = if (salt.isEmpty()) ByteArray(32) else salt
        return hmacSha256(effectiveSalt, ikm)
    }

    /** RFC 5869 HKDF-Expand. */
    fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length > 0 && length <= 255 * 32) { "invalid HKDF output length $length" }
        val out = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            val block = hmacSha256(prk, previous, info, byteArrayOf(counter.toByte()))
            val take = minOf(block.size, length - offset)
            System.arraycopy(block, 0, out, offset, take)
            offset += take
            previous = block
            counter++
        }
        return out
    }

    /** RFC 5869 HKDF-SHA256, extract-then-expand. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray =
        hkdfExpand(hkdfExtract(salt, ikm), info, length)

    /** Constant-time comparison; both proofs and tags are compared with this. */
    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].toInt() xor b[i].toInt())
        return diff == 0
    }

    fun hex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) sb.append(String.format("%02x", b))
        return sb.toString()
    }

    fun unhex(s: String): ByteArray {
        require(s.length % 2 == 0) { "hex string must have even length" }
        val out = ByteArray(s.length / 2)
        for (i in out.indices) {
            out[i] = ((Character.digit(s[i * 2], 16) shl 4) or Character.digit(s[i * 2 + 1], 16)).toByte()
        }
        return out
    }
}
