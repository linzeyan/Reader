package com.zeyanlin.novelreader.services

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * What kind of connection this device is on — the iOS `NetworkMonitor.Connection`. Only
 * chapter downloads consult it: a whole book fetched with the phone in a pocket is the one
 * thing here that can quietly spend somebody's data plan.
 */
enum class Connection {
    /** No report yet. Not metered in the foreground; not Wi-Fi for a queue nobody started. */
    UNKNOWN,
    OFFLINE,
    WIFI,
    CELLULAR,
    ;

    companion object {
        /**
         * Metered, not the transport: a phone tethered to a hotspot is on Wi-Fi and still
         * spending someone's cellular data, which is iOS folding `isExpensive` into cellular.
         */
        fun classify(available: Boolean, notMetered: Boolean): Connection = when {
            !available -> OFFLINE
            notMetered -> WIFI
            else -> CELLULAR
        }
    }
}

/** Which connections downloads may run on — the iOS `DownloadSettings.NetworkPolicy`. */
enum class NetworkPolicy(val raw: String, val label: String) {
    WIFI_ONLY("wifiOnly", "僅 Wi-Fi"),
    WIFI_AND_CELLULAR("wifiAndCellular", "Wi-Fi 與行動網路"),
    ;

    /** Whether starting or resuming a download here has to ask first. */
    fun needsConfirmation(on: Connection) = this == WIFI_ONLY && on == Connection.CELLULAR

    /**
     * Whether a download may run with nobody there to ask. Stricter than [needsConfirmation]
     * on purpose: an unreported connection asks nothing of someone holding the phone, but
     * must not spend data while it is in a pocket.
     */
    fun allowsUnattendedDownload(on: Connection) = when (this) {
        WIFI_ONLY -> on == Connection.WIFI
        WIFI_AND_CELLULAR -> on != Connection.OFFLINE
    }

    companion object {
        /** Wi-Fi only unless the reader said otherwise: the answer that cannot surprise anyone with a bill. */
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: WIFI_ONLY
    }
}

/** Follows the default network for the life of the process; the policy never stops mattering. */
class NetworkMonitor(context: Context) {
    private val state = MutableStateFlow(Connection.UNKNOWN)
    val connection: StateFlow<Connection> = state

    init {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        // No default network means no callback at all, which would read as "not reported yet".
        if (manager.activeNetwork == null) state.value = Connection.OFFLINE
        manager.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                state.value = Connection.classify(
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                )
            }

            override fun onLost(network: Network) {
                state.value = Connection.OFFLINE
            }
        })
    }
}
