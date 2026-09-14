package app.tandem.receiver

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address

/** What the idle screen tells the user about LAN reachability. */
data class NetworkStatus(val onWifi: Boolean, val ipv4: String?)

object NetworkProbe {
    fun current(context: Context): NetworkStatus {
        val cm =
            context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager ?: return NetworkStatus(false, null)
        val network = cm.activeNetwork ?: return NetworkStatus(false, null)
        val capabilities = cm.getNetworkCapabilities(network) ?: return NetworkStatus(false, null)
        val onWifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        val address =
            cm.getLinkProperties(network)
                ?.linkAddresses
                ?.map { it.address }
                ?.filterIsInstance<Inet4Address>()
                ?.firstOrNull { !it.isLoopbackAddress }
                ?.hostAddress
        return NetworkStatus(onWifi, address)
    }
}
