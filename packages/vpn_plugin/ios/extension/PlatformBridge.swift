import Foundation
import Libbox
import Network
import NetworkExtension

/// Implements the two sing-box libbox callback protocols. Holds a weak ref to
/// the provider to avoid a retain cycle with the Go-side CommandServer.
final class PlatformBridge: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private weak var provider: PacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var monitor: NWPathMonitor?

    init(_ provider: PacketTunnelProvider) {
        self.provider = provider
    }

    func reset() {
        networkSettings = nil
        monitor?.cancel()
        monitor = nil
    }

    // MARK: - Tun

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [weak self] in
            try await self?.openTun0(options, ret0_)
        }
    }

    private func openTun0(_ options: (any LibboxTunOptionsProtocol)?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let tunnel = provider else { throw TunnelError("Provider released") }
        guard let options else { throw TunnelError("Nil tun options") }
        guard let ret0_ else { throw TunnelError("Nil return pointer") }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            let dnsServer = try options.getDNSServerAddress()
            let dnsSettings = NEDNSSettings(servers: [dnsServer.value])

            // IPv4
            var ipv4Address: [String] = []
            var ipv4Mask: [String] = []
            if let it = options.getInet4Address() {
                while it.hasNext() {
                    let p = it.next()!
                    ipv4Address.append(p.address())
                    ipv4Mask.append(p.mask())
                }
            }
            let ipv4Settings = NEIPv4Settings(addresses: ipv4Address, subnetMasks: ipv4Mask)
            var ipv4Routes: [NEIPv4Route] = []
            if let it = options.getInet4RouteAddress(), it.hasNext() {
                while it.hasNext() {
                    let p = it.next()!
                    ipv4Routes.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
                }
            } else {
                ipv4Routes.append(NEIPv4Route.default())
            }
            var ipv4Excluded: [NEIPv4Route] = []
            if let it = options.getInet4RouteExcludeAddress() {
                while it.hasNext() {
                    let p = it.next()!
                    ipv4Excluded.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
                }
            }
            ipv4Settings.includedRoutes = ipv4Routes
            ipv4Settings.excludedRoutes = ipv4Excluded
            settings.ipv4Settings = ipv4Settings

            // IPv6
            var ipv6Address: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            if let it = options.getInet6Address() {
                while it.hasNext() {
                    let p = it.next()!
                    ipv6Address.append(p.address())
                    ipv6Prefixes.append(NSNumber(value: p.prefix()))
                }
            }
            if !ipv6Address.isEmpty {
                let ipv6Settings = NEIPv6Settings(addresses: ipv6Address, networkPrefixLengths: ipv6Prefixes)
                var ipv6Routes: [NEIPv6Route] = []
                if let it = options.getInet6RouteAddress(), it.hasNext() {
                    while it.hasNext() {
                        let p = it.next()!
                        ipv6Routes.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix())))
                    }
                } else {
                    ipv6Routes.append(NEIPv6Route.default())
                }
                var ipv6Excluded: [NEIPv6Route] = []
                if let it = options.getInet6RouteExcludeAddress() {
                    while it.hasNext() {
                        let p = it.next()!
                        ipv6Excluded.append(NEIPv6Route(destinationAddress: p.address(), networkPrefixLength: NSNumber(value: p.prefix())))
                    }
                }
                ipv6Settings.includedRoutes = ipv6Routes
                ipv6Settings.excludedRoutes = ipv6Excluded
                settings.ipv6Settings = ipv6Settings
            }

            // Split-tunnel (no 0.0.0.0/0): scope tunnel DNS so it isn't
            // registered as the unconditional system default resolver.
            let hasDefaultRoute = ipv4Routes.contains {
                $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
            }
            if !hasDefaultRoute {
                dnsSettings.matchDomains = [""]
                dnsSettings.matchDomainsNoSearch = true
            }

            settings.dnsSettings = dnsSettings
        }

        networkSettings = settings
        extLog("openTun: applying network settings (autoRoute=\(options.getAutoRoute()) mtu=\(options.getMTU()))")
        try await tunnel.setTunnelNetworkSettings(settings)
        extLog("openTun: network settings applied")

        let kvcFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 ?? -1
        if kvcFd != -1 {
            extLog("openTun: got tun fd \(kvcFd) (KVC)")
            ret0_.pointee = kvcFd
            return
        }
        let loopFd = LibboxGetTunnelFileDescriptor()
        if loopFd != -1 {
            extLog("openTun: got tun fd \(loopFd) (libbox)")
            ret0_.pointee = loopFd
        } else {
            extLog("openTun: NO tun fd (KVC and libbox both -1)")
            throw TunnelError("Missing tunnel file descriptor")
        }
    }

    // MARK: - Interface monitor

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_: Int32) throws {}

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.emit(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { [weak self] path in self?.emit(listener, path) }
        }
        monitor.start(queue: DispatchQueue.global())
        semaphore.wait()
    }

    private func emit(_ listener: any LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        guard path.status != .unsatisfied, let iface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(iface.name, interfaceIndex: Int32(iface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    func closeDefaultInterfaceMonitor(_: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        monitor?.cancel()
        monitor = nil
    }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        guard let monitor else { return InterfaceIterator([]) }
        let path = monitor.currentPath
        if path.status == .unsatisfied { return InterfaceIterator([]) }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let i = LibboxNetworkInterface()
            i.name = it.name
            i.index = Int32(it.index)
            switch it.type {
            case .wifi: i.type = LibboxInterfaceTypeWIFI
            case .cellular: i.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: i.type = LibboxInterfaceTypeEthernet
            default: i.type = LibboxInterfaceTypeOther
            }
            interfaces.append(i)
        }
        return InterfaceIterator(interfaces)
    }

    // MARK: - Misc platform hooks

    func useProcFS() -> Bool { false }

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }

    func clearDNSCache() {
        guard let tunnel = provider, let settings = networkSettings else { return }
        // Suppress the transient status flip the app would otherwise see during
        // this nil → re-apply cycle (a routine DNS flush is not a disconnect).
        tunnel.reasserting = true
        defer { tunnel.reasserting = false }
        runBlocking {
            await withCheckedContinuation { c in
                tunnel.setTunnelNetworkSettings(nil) { _ in c.resume() }
            }
            await withCheckedContinuation { c in
                tunnel.setTunnelNetworkSettings(settings) { _ in c.resume() }
            }
        }
    }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func send(_: LibboxNotification?) throws {}

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw TunnelError("Not supported")
    }

    // MARK: - CommandServerHandler

    func serviceStop() throws {
        provider?.stopService()
    }

    func serviceReload() throws {}

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_: Bool) throws {}

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        provider?.writeMessage(message)
    }
}

/// Bridges an array of interfaces to the libbox iterator protocol.
private final class InterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var current: LibboxNetworkInterface?

    init(_ array: [LibboxNetworkInterface]) {
        iterator = array.makeIterator()
    }

    func hasNext() -> Bool {
        current = iterator.next()
        return current != nil
    }

    func next() -> LibboxNetworkInterface? { current }
}
