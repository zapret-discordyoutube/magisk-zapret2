package com.zapret2.app.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.zapret2.app.AppDebugLog
import java.lang.ref.WeakReference

/**
 * Reports the active transport of the device to the control screen.
 *
 * Firewall ownership and topology are interpreted only by the module lifecycle boundary. The app
 * deliberately does not read privileged owner metadata or parse firewall rules a second time: doing
 * so creates a competing contract and can reject a topology that the module has already verified
 * and published. What the screen shows of the module's own firewall record — whether the ruleset is
 * active and how many NFQUEUE rules it counted — is taken straight from the typed status snapshot
 * in `ControlViewModel`, so there is no second projection of it here to drift out of date.
 */
class NetworkStatsManager(context: Context) {

    companion object {
        private const val TAG = "NetworkStatsManager"
    }

    private val contextRef = WeakReference(context.applicationContext)

    private val connectivityManager: ConnectivityManager? by lazy {
        contextRef.get()?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    }

    enum class NetworkType {
        WIFI,
        MOBILE,
        ETHERNET,
        VPN,
        NONE,
    }

    fun getNetworkType(): NetworkType {
        val cm = connectivityManager ?: return NetworkType.NONE

        return try {
            val activeNetwork = cm.activeNetwork ?: return NetworkType.NONE
            val capabilities = cm.getNetworkCapabilities(activeNetwork) ?: return NetworkType.NONE

            when {
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> NetworkType.VPN
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkType.WIFI
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkType.MOBILE
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> NetworkType.ETHERNET
                else -> NetworkType.NONE
            }
        } catch (error: Exception) {
            AppDebugLog.error(TAG, "Error getting network type", error)
            NetworkType.NONE
        }
    }
}
