package app.tandem.receiver.store

/**
 * Persistence for `hostId → 32-byte shared secret` (PROTOCOL.md §3.3) and the
 * receiver's own stable identity. Kept as an interface so the session logic is
 * testable off-device.
 */
interface PairedHostStore {
    /** Stable per-install receiver identity, reported as `hello_ack.deviceId`. */
    fun deviceId(): String

    fun secretFor(hostId: String): ByteArray?

    fun store(hostId: String, secret: ByteArray)

    fun forget(hostId: String)

    fun forgetAll()

    /** Host ids with a stored secret, for the settings screen. */
    fun pairedHostIds(): Set<String>

    fun isPaired(hostId: String): Boolean = secretFor(hostId) != null
}
