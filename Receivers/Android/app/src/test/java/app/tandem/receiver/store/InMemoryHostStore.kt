package app.tandem.receiver.store

import java.util.UUID

/** A [PairedHostStore] with no persistence, used by the JVM protocol tests. */
class InMemoryHostStore(private val deviceId: String = UUID.randomUUID().toString()) : PairedHostStore {
    private val secrets = HashMap<String, ByteArray>()

    override fun deviceId(): String = deviceId

    override fun secretFor(hostId: String): ByteArray? = secrets[hostId]

    override fun store(hostId: String, secret: ByteArray) {
        secrets[hostId] = secret
    }

    override fun forget(hostId: String) {
        secrets.remove(hostId)
    }

    override fun forgetAll() = secrets.clear()

    override fun pairedHostIds(): Set<String> = secrets.keys.toSet()
}
