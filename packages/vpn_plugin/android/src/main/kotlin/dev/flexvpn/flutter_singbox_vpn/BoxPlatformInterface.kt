package dev.flexvpn.flutter_singbox_vpn

import android.net.ConnectivityManager
import android.content.Context
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.LinkProperties
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.system.Os
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterface
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/// Implements sing-box's libbox callbacks for Android: builds the VpnService TUN,
/// protects proxy sockets (so they bypass the tunnel), and reports the default
/// network interface. Also serves as the CommandServerHandler.
class BoxPlatformInterface(private val context: Context, private val service: SingBoxVpnService? = null) :
    PlatformInterface, CommandServerHandler {

    constructor(service: SingBoxVpnService) : this(service, service)

    private val connectivity: ConnectivityManager? =
        context.getSystemService(ConnectivityManager::class.java)
    private var monitorCallback: ConnectivityManager.NetworkCallback? = null
    private var monitorThread: HandlerThread? = null
    @Volatile private var underlyingNetwork: Network? = null
    private val resolver = UnderlyingDnsResolver { underlyingNetwork }

    // MARK: TUN

    override fun openTun(options: TunOptions): Int {
        val vpnService = service ?: throw IllegalStateException("probe cannot open a VPN tunnel")
        val builder = vpnService.Builder()
        builder.setMtu(options.getMTU())
        builder.setSession("BMray")
        // The separate Xray CLI cannot call VpnService.protect on its own sockets.
        // Exclude only our app UID while it is running; all other apps use TUN.
        if (vpnService.xrayActive) builder.addDisallowedApplication(context.packageName)

        val v4 = options.getInet4Address()
        while (v4.hasNext()) {
            val p = v4.next()
            builder.addAddress(p.address(), p.prefix())
        }
        var hasV6 = false
        val v6 = options.getInet6Address()
        while (v6.hasNext()) {
            val p = v6.next()
            builder.addAddress(p.address(), p.prefix())
            hasV6 = true
        }

        if (options.getAutoRoute()) {
            // Prefer the precomputed route RANGE (it already subtracts any
            // route_exclude_address); fall back to a full default route.
            val rr4 = options.getInet4RouteRange()
            if (rr4.hasNext()) {
                while (rr4.hasNext()) {
                    val p = rr4.next()
                    builder.addRoute(p.address(), p.prefix())
                }
            } else {
                builder.addRoute("0.0.0.0", 0)
            }
            if (hasV6) {
                val rr6 = options.getInet6RouteRange()
                if (rr6.hasNext()) {
                    while (rr6.hasNext()) {
                        val p = rr6.next()
                        builder.addRoute(p.address(), p.prefix())
                    }
                } else {
                    builder.addRoute("::", 0)
                }
            }
            builder.addDnsServer(options.getDNSServerAddress().getValue())
        }

        builder.setBlocking(false)
        val pfd = builder.establish()
            ?: throw IllegalStateException("VpnService not prepared / establish() failed")
        vpnService.tunFd = pfd
        return pfd.fd
    }

    // MARK: interface control (bypass the tunnel for proxy sockets)

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        if (service != null && !service.protect(fd)) {
            throw IllegalStateException("protect($fd) failed")
        }
        val network = underlyingNetwork
            ?: throw IllegalStateException("No underlying Wi-Fi or mobile network")
        // Bind only this socket, never the whole process (which must use the VPN).
        ParcelFileDescriptor.fromFd(fd).use { network.bindSocket(it.fileDescriptor) }
    }

    // MARK: default-interface monitor (ConnectivityManager)

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val cm = connectivity ?: throw IllegalStateException("ConnectivityManager unavailable")
        val latch = CountDownLatch(1)
        fun update(network: Network, properties: LinkProperties? = null) {
            underlyingNetwork = network
            service?.setUnderlyingNetworks(arrayOf(network))
            if (emit(network, listener, properties)) latch.countDown()
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                update(network)
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                if (network == underlyingNetwork) update(network)
            }

            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                if (network == underlyingNetwork) update(network, properties)
            }

            override fun onLost(network: Network) {
                // Losing an old network after a handover must not clear the new one.
                if (network == underlyingNetwork) {
                    underlyingNetwork = null
                    service?.setUnderlyingNetworks(null)
                    listener.updateDefaultInterface("", -1, false, false)
                }
            }
        }
        monitorCallback = callback
        // Ask Android for the BEST non-VPN network. Listening to every matching
        // network picks whichever callback arrives last, including idle mobile data.
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
        val thread = HandlerThread("bmray-network").also { it.start() }
        monitorThread = thread
        val handler = Handler(thread.looper)
        if (Build.VERSION.SDK_INT >= 31) {
            cm.registerBestMatchingNetworkCallback(request, callback, handler)
        } else if (Build.VERSION.SDK_INT >= 26) {
            cm.requestNetwork(request, callback, handler)
        } else {
            cm.requestNetwork(request, callback)
        }
        if (!latch.await(5, TimeUnit.SECONDS)) {
            throw IllegalStateException("Wi-Fi/mobile network is unavailable; check connectivity and retry")
        }
    }

    private fun emit(network: Network, listener: InterfaceUpdateListener, properties: LinkProperties? = null): Boolean {
        val cm = connectivity ?: return false
        val name = (properties ?: cm.getLinkProperties(network))?.interfaceName
        if (name == null) {
            service?.writeExtLog("monitor: underlying network has no interfaceName yet")
            return false
        }
        val caps = cm.getNetworkCapabilities(network)
        val index = try { Os.if_nametoindex(name) } catch (e: Exception) { -1 }
        if (index <= 0) return false
        val expensive = caps != null &&
            !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        service?.writeExtLog("monitor: default underlying iface=$name index=$index expensive=$expensive")
        listener.updateDefaultInterface(name, index, expensive, false)
        return true
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        closeMonitor()
    }

    fun closeMonitor() {
        val cm = connectivity ?: return
        monitorCallback?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        monitorCallback = null
        monitorThread?.quitSafely()
        monitorThread = null
        underlyingNetwork = null
        resolver.close()
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val list = ArrayList<NetworkInterface>()
        try {
            val cm = connectivity
            if (cm != null) {
                for (network in cm.allNetworks) {
                    val caps = cm.getNetworkCapabilities(network) ?: continue
                    if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) continue
                    val properties = cm.getLinkProperties(network) ?: continue
                    val ni = java.net.NetworkInterface.getByName(properties.interfaceName) ?: continue
                    if (ni.isLoopback || !ni.isUp) continue
                    val item = NetworkInterface()
                    item.setName(ni.name)
                    item.setIndex(ni.index)
                    item.setAddresses(ArrayStringIterator(ni.interfaceAddresses.mapNotNull {
                        val address = it.address.hostAddress?.substringBefore('%') ?: return@mapNotNull null
                        "$address/${it.networkPrefixLength}"
                    }))
                    item.setDNSServer(ArrayStringIterator(properties.dnsServers.mapNotNull { it.hostAddress }))
                    item.setMetered(!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED))
                    try { item.setMTU(ni.mtu) } catch (_: Exception) {}
                    // Go net.Flags: Up=1, Broadcast=2, Loopback=4, PointToPoint=8,
                    // Multicast=16, Running=32. sing-box filters out interfaces
                    // that aren't Up/Running, so these MUST be set.
                    var flags = 0x1 or 0x20 // Up | Running
                    try { if (ni.supportsMulticast()) flags = flags or 0x10 } catch (_: Exception) {}
                    try { if (ni.isPointToPoint) flags = flags or 0x8 else flags = flags or 0x2 } catch (_: Exception) {}
                    item.setFlags(flags)
                    item.setType(when {
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> io.nekohasekai.libbox.Libbox.InterfaceTypeWIFI
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> io.nekohasekai.libbox.Libbox.InterfaceTypeCellular
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> io.nekohasekai.libbox.Libbox.InterfaceTypeEthernet
                        else -> io.nekohasekai.libbox.Libbox.InterfaceTypeOther
                    }.toInt())
                    list.add(item)
                }
            }
        } catch (e: Exception) {
            service?.writeExtLog("getInterfaces error: ${e.message}")
        }
        service?.writeExtLog("getInterfaces -> " + list.joinToString(", ") { "${it.name}#${it.index}" })
        return ArrayInterfaceIterator(list)
    }

    private class ArrayStringIterator(private val values: List<String>) : StringIterator {
        private var index = 0
        override fun hasNext(): Boolean = index < values.size
        override fun next(): String = values[index++]
        override fun len(): Int = values.size
    }

    private class ArrayInterfaceIterator(private val list: List<NetworkInterface>) :
        NetworkInterfaceIterator {
        private var i = 0
        override fun hasNext(): Boolean = i < list.size
        override fun next(): NetworkInterface = list[i++]
    }

    // MARK: unused-on-Android hooks (safe defaults)

    override fun useProcFS(): Boolean = false
    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun clearDNSCache() {}
    override fun readWIFIState(): WIFIState? = null
    override fun systemCertificates(): StringIterator? = null
    override fun localDNSTransport(): LocalDNSTransport = resolver
    override fun sendNotification(notification: Notification?) {}

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String?,
        sourcePort: Int,
        destinationAddress: String?,
        destinationPort: Int,
    ): ConnectionOwner {
        // Return "unknown owner" instead of throwing: sing-box on Android may
        // probe this per connection, and throwing spams logs / disrupts routing.
        val owner = ConnectionOwner()
        owner.userId = -1
        return owner
    }

    // MARK: CommandServerHandler

    override fun serviceStop() { service?.stopTunnel() }
    override fun serviceReload() {}
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()
    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun writeDebugMessage(message: String?) { message?.let { service?.writeExtLog(it) } }
}
