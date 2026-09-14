package app.teras.receiver.store

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.util.UUID

/**
 * Persists `hostId → secret` (PROTOCOL.md §3.3) and the receiver's stable
 * device id.
 *
 * Secrets are held in [EncryptedSharedPreferences], keyed by an AES-256-GCM
 * master key in the platform keystore. That library has a long history of
 * throwing on devices whose keystore has been reset or whose entry no longer
 * matches the stored file, and a receiver that cannot start is worse than one
 * whose pairing secrets are merely uid-private, so a failure falls back to an
 * ordinary `MODE_PRIVATE` file with Base64 values. The fallback is visible to
 * the caller through [isEncrypted] rather than being silent.
 */
class SharedPreferencesHostStore(context: Context) : PairedHostStore {
    private val appContext = context.applicationContext

    private val prefs: SharedPreferences
    private val encrypted: Boolean

    init {
        val secure = openEncrypted(appContext)
        prefs = secure ?: openPlain(appContext)
        encrypted = secure != null
        if (!encrypted) {
            Log.w(TAG, "keystore-backed preferences unavailable; using uid-private storage")
        }
    }

    /** False when the keystore was unusable and the plain fallback is in use. */
    val isEncrypted: Boolean get() = encrypted

    override fun deviceId(): String {
        prefs.getString(KEY_DEVICE_ID, null)?.let { return it }
        val generated = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_DEVICE_ID, generated).apply()
        return generated
    }

    override fun secretFor(hostId: String): ByteArray? {
        val encoded =
            try {
                prefs.getString(hostKey(hostId), null)
            } catch (e: Exception) {
                // A keystore entry that no longer decrypts this file surfaces
                // here; treat it as unpaired rather than failing the handshake.
                Log.w(TAG, "cannot read the stored secret", e)
                null
            } ?: return null

        return try {
            java.util.Base64.getDecoder().decode(encoded)
        } catch (_: IllegalArgumentException) {
            prefs.edit().remove(hostKey(hostId)).apply()
            null
        }
    }

    override fun store(hostId: String, secret: ByteArray) {
        prefs.edit()
            .putString(hostKey(hostId), java.util.Base64.getEncoder().encodeToString(secret))
            .apply()
    }

    override fun forget(hostId: String) {
        prefs.edit().remove(hostKey(hostId)).apply()
    }

    override fun forgetAll() {
        val editor = prefs.edit()
        pairedHostIds().forEach { editor.remove(hostKey(it)) }
        editor.apply()
    }

    override fun pairedHostIds(): Set<String> =
        try {
            prefs.all.keys.filter { it.startsWith(PREFIX_HOST) }.map { it.removePrefix(PREFIX_HOST) }
                .toSet()
        } catch (e: Exception) {
            Log.w(TAG, "cannot enumerate paired hosts", e)
            emptySet()
        }

    private fun hostKey(hostId: String) = PREFIX_HOST + hostId

    private companion object {
        const val TAG = "PairedHostStore"
        const val SECURE_FILE = "teras_paired_hosts_secure"

        /** Deliberately a different file, so the two never share a backing store. */
        const val PLAIN_FILE = "teras_paired_hosts"
        const val KEY_DEVICE_ID = "device_id"
        const val PREFIX_HOST = "host_"

        fun openEncrypted(context: Context): SharedPreferences? {
            createEncrypted(context)?.let { return it }
            // One retry after discarding a file the current key cannot open,
            // which is what a keystore reset or a restored backup leaves behind.
            return if (context.deleteSharedPreferences(SECURE_FILE)) {
                createEncrypted(context)
            } else {
                null
            }
        }

        private fun createEncrypted(context: Context): SharedPreferences? =
            try {
                val masterKey =
                    MasterKey.Builder(context)
                        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                        .build()
                EncryptedSharedPreferences.create(
                    context,
                    SECURE_FILE,
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                ).also {
                    // Force a read: create() can succeed and the first access
                    // still throw when the file and the key disagree.
                    it.all
                }
            } catch (e: Exception) {
                Log.w(TAG, "EncryptedSharedPreferences unavailable", e)
                null
            }

        fun openPlain(context: Context): SharedPreferences =
            context.getSharedPreferences(PLAIN_FILE, Context.MODE_PRIVATE)
    }
}
