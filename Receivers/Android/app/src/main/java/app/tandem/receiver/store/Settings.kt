package app.tandem.receiver.store

import android.content.Context
import android.os.Build

/** User-visible preferences, backed by a private SharedPreferences file. */
class Settings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** The name shown on the Mac and advertised over Bonjour. */
    var deviceName: String
        get() = prefs.getString(KEY_NAME, null) ?: defaultDeviceName()
        set(value) {
            val trimmed = value.trim().take(MAX_NAME_LENGTH)
            prefs.edit().putString(KEY_NAME, trimmed.ifEmpty { defaultDeviceName() }).apply()
        }

    var keepScreenOn: Boolean
        get() = prefs.getBoolean(KEY_KEEP_SCREEN_ON, true)
        set(value) = prefs.edit().putBoolean(KEY_KEEP_SCREEN_ON, value).apply()

    var showStats: Boolean
        get() = prefs.getBoolean(KEY_SHOW_STATS, false)
        set(value) = prefs.edit().putBoolean(KEY_SHOW_STATS, value).apply()

    private fun defaultDeviceName(): String {
        val manufacturer = Build.MANUFACTURER.orEmpty().replaceFirstChar { it.uppercase() }
        val model = Build.MODEL.orEmpty()
        return when {
            model.isEmpty() -> "Android"
            model.startsWith(manufacturer, ignoreCase = true) -> model
            manufacturer.isEmpty() -> model
            else -> "$manufacturer $model"
        }
    }

    private companion object {
        const val FILE = "tandem_settings"
        const val KEY_NAME = "device_name"
        const val KEY_KEEP_SCREEN_ON = "keep_screen_on"
        const val KEY_SHOW_STATS = "show_stats"
        const val MAX_NAME_LENGTH = 63
    }
}
