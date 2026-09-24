package dev.flexvpn.flutter_singbox_vpn

import android.net.Network
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.Inet4Address
import java.net.Inet6Address
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Bootstrap only: resolve the proxy hostname on a physical network, not the TUN. */
class UnderlyingDnsResolver(private val network: () -> Network?) : LocalDNSTransport {
    private val executor = Executors.newFixedThreadPool(2)

    override fun raw(): Boolean = false

    override fun lookup(ctx: ExchangeContext, family: String, domain: String) {
        val selected = network() ?: throw IllegalStateException("No underlying network for DNS")
        val task = executor.submit(Callable { selected.getAllByName(domain.trimEnd('.')).toList() })
        ctx.onCancel { task.cancel(true) }
        try {
            val addresses = task.get(10, TimeUnit.SECONDS).filter {
                when {
                    family.endsWith("4") -> it is Inet4Address
                    family.endsWith("6") -> it is Inet6Address
                    else -> true
                }
            }
            ctx.success(addresses.mapNotNull { it.hostAddress }.joinToString("\n"))
        } finally {
            task.cancel(true)
        }
    }

    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        throw UnsupportedOperationException("Use A/AAAA lookup for platform DNS")
    }

    fun close() { executor.shutdownNow() }
}
