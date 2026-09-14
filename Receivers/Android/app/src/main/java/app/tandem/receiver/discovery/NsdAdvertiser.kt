package app.tandem.receiver.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import app.tandem.receiver.net.Protocol

/**
 * Advertises `_tandem._tcp` so the Mac can find this receiver on the LAN
 * (PROTOCOL.md §1.1). USB sessions do not need it — the host reaches the same
 * port through `adb forward` — but it costs nothing to keep running.
 */
class NsdAdvertiser(context: Context) {
    private val nsdManager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var listener: NsdManager.RegistrationListener? = null

    @Volatile var registeredName: String? = null
        private set

    /** Registers, replacing any previous registration. */
    fun register(deviceId: String, deviceName: String, port: Int = Protocol.PORT) {
        unregister()
        val info =
            NsdServiceInfo().apply {
                serviceName = deviceName.ifBlank { "Tandem" }
                serviceType = "${Protocol.SERVICE_TYPE}."
                this.port = port
                setAttribute("pv", Protocol.VERSION.toString())
                setAttribute("id", deviceId)
                setAttribute("plat", Protocol.PLATFORM)
                setAttribute("name", deviceName)
            }

        val registrationListener =
            object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) {
                    // Bonjour may have renamed us to break a collision.
                    registeredName = info.serviceName
                    Log.i(TAG, "registered as ${info.serviceName}")
                }

                override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                    registeredName = null
                    Log.w(TAG, "registration failed with code $errorCode")
                }

                override fun onServiceUnregistered(info: NsdServiceInfo) {
                    registeredName = null
                }

                override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                    registeredName = null
                    Log.w(TAG, "unregistration failed with code $errorCode")
                }
            }

        listener = registrationListener
        try {
            nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registrationListener)
        } catch (e: IllegalArgumentException) {
            listener = null
            Log.w(TAG, "cannot register the Bonjour service", e)
        }
    }

    fun unregister() {
        val current = listener ?: return
        listener = null
        registeredName = null
        try {
            nsdManager.unregisterService(current)
        } catch (e: IllegalArgumentException) {
            // Already unregistered by the framework; nothing to undo.
            Log.d(TAG, "service was not registered", e)
        }
    }

    private companion object {
        const val TAG = "NsdAdvertiser"
    }
}
