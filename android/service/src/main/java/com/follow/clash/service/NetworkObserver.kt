package com.follow.clash.service

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkCapabilities.TRANSPORT_SATELLITE
import android.net.NetworkCapabilities.TRANSPORT_USB
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import androidx.core.content.getSystemService
import com.follow.clash.common.GlobalState
import com.follow.clash.core.Core
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap

private data class NetworkInfo(
    val name: String,
    @Volatile var losingUntilMillis: Long = 0,
    @Volatile var dnsList: List<InetAddress> = emptyList(),
) {
    val priorityPenalty: Int
        get() = if (losingUntilMillis > System.currentTimeMillis()) 10 else 0
}

// Outlives every service run: the Core also tests delays and updates providers
// while stopped, and a `system` nameserver has no upstream until DNS arrives here.
object NetworkObserver {

    private val networkInfos = ConcurrentHashMap<Network, NetworkInfo>()
    private val connectivity by lazy {
        GlobalState.application.getSystemService<ConnectivityManager>()
    }
    private val handler by lazy {
        Handler(HandlerThread("NetworkObserve").apply { start() }.looper)
    }
    private var currentDnsList = listOf<String>()
    private var currentNetwork: Network? = null
    private var started = false

    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            addCapability(NetworkCapabilities.NET_CAPABILITY_FOREGROUND)
        }
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
    }.build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val info = NetworkInfo(describe(network))
            networkInfos[network] = info
            GlobalState.log("[NET] ${info.name} available")
            scheduleUpdateDns()
        }

        override fun onLosing(network: Network, maxMsToLive: Int) {
            val info = networkInfos[network] ?: return
            info.losingUntilMillis = System.currentTimeMillis() + maxMsToLive
            GlobalState.log("[NET] ${info.name} losing, ${maxMsToLive}ms left")
            scheduleUpdateDns()
            if (maxMsToLive > 0) {
                handler.postDelayed({
                    if (networkInfos.containsKey(network)) {
                        updateDns()
                    }
                }, maxMsToLive.toLong() + 50)
            }
        }

        override fun onLost(network: Network) {
            val info = networkInfos.remove(network)
            if (info != null) {
                GlobalState.log("[NET] ${info.name} lost")
            }
            scheduleUpdateDns()
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            val info = networkInfos[network]
            val dns = linkProperties.dnsServers
            if (info != null && dns != info.dnsList) {
                GlobalState.log("[NET] ${info.name} dns ${describeDns(dns)}")
            }
            info?.dnsList = dns
            scheduleUpdateDns()
        }
    }

    private val updateDnsTask = Runnable(::updateDns)

    // A switch arrives as a burst, and a network that just came up has no DNS
    // until its link properties follow; the Core flushes its cache per list.
    private fun scheduleUpdateDns() {
        handler.removeCallbacks(updateDnsTask)
        handler.postDelayed(updateDnsTask, DNS_UPDATE_DELAY_MILLIS)
    }

    // A bare Network{100} handle says nothing a month later, so the log
    // carries the transport the handle came from.
    private fun describe(network: Network): String {
        val capabilities = connectivity?.getNetworkCapabilities(network)
        val transport = when {
            capabilities == null -> "gone"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "other"
        }
        return "$transport $network"
    }

    private fun describeDns(addresses: List<InetAddress>): String =
        addresses.joinToString(",") { it.asSocketAddressText(DNS_PORT) }.ifEmpty { "none" }

    @Synchronized
    fun start() {
        if (started) return
        runCatching { requireNotNull(connectivity).registerNetworkCallback(request, callback) }
            .onSuccess { started = true }
            .onFailure { error -> GlobalState.log("[NET] unable to observe networks: $error") }
    }

    private fun networkPriority(entry: Map.Entry<Network, NetworkInfo>): Int {
        val capabilities = connectivity?.getNetworkCapabilities(entry.key)
        return when {
            capabilities == null -> 100
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> 90
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 1
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                capabilities.hasTransport(TRANSPORT_USB) -> 2

            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> 3
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 4
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
                capabilities.hasTransport(TRANSPORT_SATELLITE) -> 5

            else -> 20
        } + entry.value.priorityPenalty
    }

    @Synchronized
    private fun updateDns() {
        val preferred = networkInfos.entries.minByOrNull(::networkPriority)
        val dnsList = preferred
            ?.value
            ?.dnsList
            .orEmpty()
            .map { address -> address.asSocketAddressText(DNS_PORT) }
            .distinct()
        if (dnsList != currentDnsList) {
            currentDnsList = dnsList
            val nameservers = dnsList.joinToString(",").ifEmpty { "none" }
            GlobalState.log("[NET] dns -> $nameservers")
            Core.updateDNS(dnsList.joinToString(","))
        }
        if (preferred == null) {
            if (currentNetwork != null) {
                GlobalState.log("[NET] no network left")
            }
            return
        }
        val network = preferred.key
        // Sockets protected onto the network we left stay bound to it; closing
        // them makes apps reconnect now instead of after a TCP timeout.
        if (currentNetwork != null && currentNetwork != network) {
            GlobalState.log("[NET] ${preferred.value.name} is preferred now, resetting connections")
            Core.resetNetwork()
        }
        currentNetwork = network
    }
}

private const val DNS_PORT = 53
private const val DNS_UPDATE_DELAY_MILLIS = 200L

private fun InetAddress.asSocketAddressText(port: Int): String = when (this) {
    is Inet6Address -> "[$hostAddress]:$port"
    is Inet4Address -> "$hostAddress:$port"
    else -> error("Unsupported address type: ${javaClass.name}")
}
