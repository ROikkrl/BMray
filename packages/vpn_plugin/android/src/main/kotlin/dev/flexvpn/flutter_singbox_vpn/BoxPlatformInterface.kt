package dev.flexvpn.flutter_singbox_vpn

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
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
class BoxPlatformInterface(private val service: SingBoxVpnService) :
    PlatformInterface, CommandServerHandler {

    private val connectivity: ConnectivityManager? =
        service.getSystemService(ConnectivityManager::class.java)
    private var monitorCallback: ConnectivityManager.NetworkCallback? = null

    // MARK: TUN

    override fun openTun(options: TunOptions): Int {
        val builder = service.Builder()
        builder.setMtu(options.getMTU())
        builder.setSession("BMray")

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
        service.tunFd = pfd
        return pfd.fd
    }

    // MARK: interface control (bypass the tunnel for proxy sockets)

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!service.protect(fd)) {
            throw IllegalStateException("protect($fd) failed")
        }
    }

    // MARK: default-interface monitor (ConnectivityManager)

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        val cm = connectivity ?: return
        val latch = CountDownLatch(1)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                emit(network, listener); latch.countDown()
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                emit(network, listener); latch.countDown()
            }

            override fun onLost(network: Network) {
                listener.updateDefaultInterface("", -1, false, false)
            }
        }
        monitorCallback = callback
        // Watch the UNDERLYING (non-VPN) network — NOT our own tunnel. Using
        // registerDefaultNetworkCallback would report the active VPN as the
        // default once the tunnel is up, so sing-box would bind outbound sockets
        // back into the tunnel and loop (symptom: connected but no traffic).
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        cm.registerNetworkCallback(request, callback)
        latch.await(2, TimeUnit.SECONDS)
    }

    private fun emit(network: Network, listener: InterfaceUpdateListener) {
        val cm = connectivity ?: return
        val name = cm.getLinkProperties(network)?.interfaceName
        if (name == null) {
            service.writeExtLog("monitor: underlying network has no interfaceName yet")
            return
        }
        val caps = cm.getNetworkCapabilities(network)
        val index = try { Os.if_nametoindex(name) } catch (e: Exception) { -1 }
        val expensive = caps != null &&
            !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        service.writeExtLog("monitor: default underlying iface=$name index=$index expensive=$expensive")
        listener.updateDefaultInterface(name, index, expensive, false)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        closeMonitor()
    }

    fun closeMonitor() {
        val cm = connectivity ?: return
        monitorCallback?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        monitorCallback = null
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val list = ArrayList<NetworkInterface>()
        try {
            val nis = java.net.NetworkInterface.getNetworkInterfaces()
            if (nis != null) {
                for (ni in nis) {
                    if (ni.isLoopback || !ni.isUp) continue
                    val item = NetworkInterface()
                    item.setName(ni.name)
                    item.setIndex(ni.index)
                    try { item.setMTU(ni.mtu) } catch (_: Exception) {}
                    // Go net.Flags: Up=1, Broadcast=2, Loopback=4, PointToPoint=8,
                    // Multicast=16, Running=32. sing-box filters out interfaces
                    // that aren't Up/Running, so these MUST be set.
                    var flags = 0x1 or 0x20 // Up | Running
                    try { if (ni.supportsMulticast()) flags = flags or 0x10 } catch (_: Exception) {}
                    try { if (ni.isPointToPoint) flags = flags or 0x8 else flags = flags or 0x2 } catch (_: Exception) {}
                    item.setFlags(flags)
                    item.setType(interfaceType(ni.name))
                    list.add(item)
                }
            }
        } catch (e: Exception) {
            service.writeExtLog("getInterfaces error: ${e.message}")
        }
        service.writeExtLog("getInterfaces -> " + list.joinToString(", ") { "${it.name}#${it.index}" })
        return ArrayInterfaceIterator(list)
    }

    private fun interfaceType(name: String): Int = when {
        name.startsWith("wlan") -> io.nekohasekai.libbox.Libbox.InterfaceTypeWIFI
        name.startsWith("rmnet") || name.startsWith("radio") || name.startsWith("ccmni") ||
            name.startsWith("pdp") || name.startsWith("radio") -> io.nekohasekai.libbox.Libbox.InterfaceTypeCellular
        name.startsWith("eth") -> io.nekohasekai.libbox.Libbox.InterfaceTypeEthernet
        else -> io.nekohasekai.libbox.Libbox.InterfaceTypeOther
    }.toInt()

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
    override fun localDNSTransport(): LocalDNSTransport? = null
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

    override fun serviceStop() { service.stopTunnel() }
    override fun serviceReload() {}
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()
    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun writeDebugMessage(message: String?) { message?.let { service.writeExtLog(it) } }
}
