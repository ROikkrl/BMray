import Foundation
import Libbox
import NetworkExtension

/// The packet-tunnel extension. Runs the sing-box core (libbox) entirely inside
/// the Network Extension process. Keeping `LibboxSetMemoryLimit(true)` on is what
/// keeps memory under the iOS NE ceiling so the process is not killed.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var commandServer: LibboxCommandServer?
    private var bridge: PlatformBridge?

    override func startTunnel(options: [String: NSObject]?) async throws {
        extLogReset()
        do {
            try await startTunnelInner(options)
        } catch {
            // Capture the SPECIFIC reason before iOS flattens it to a generic
            // "TunnelError error 1" in the system disconnect error.
            extLog("startTunnel FAILED: \(error.localizedDescription)")
            throw error
        }
    }

    private func startTunnelInner(_ options: [String: NSObject]?) async throws {
        let base = FilePath.sharedDirectory
        let working = FilePath.workingDirectory
        let cache = FilePath.cacheDirectory
        extLog("begin; base=\(base.path)")

        let setup = LibboxSetupOptions()
        setup.basePath = base.path
        setup.workingPath = working.path
        setup.tempPath = cache.path
        setup.logMaxLines = 3000

        var setupErr: NSError?
        LibboxSetup(setup, &setupErr)
        if let setupErr { throw TunnelError("setup: \(setupErr.localizedDescription)") }

        var stderrErr: NSError?
        LibboxRedirectStderr(cache.appendingPathComponent("stderr.log").path, &stderrErr)

        // Critical for "not killed on iOS": let sing-box honor the NE memory limit.
        LibboxSetMemoryLimit(true)
        extLog("setup ok")

        let bridge = PlatformBridge(self)
        self.bridge = bridge

        var cmdErr: NSError?
        guard let server = LibboxNewCommandServer(bridge, bridge, &cmdErr) else {
            throw TunnelError("command server: \(cmdErr?.localizedDescription ?? "unknown")")
        }
        commandServer = server
        try server.start()
        extLog("command server started")

        let configContent = try resolveConfig(options)
        extLog("config resolved (\(configContent.count) bytes); starting service…")
        let override = LibboxOverrideOptions()
        do {
            try server.startOrReloadService(configContent, options: override)
        } catch {
            throw TunnelError("start service: \(error.localizedDescription)")
        }
        extLog("tunnel started OK")
        writeMessage("tunnel started")
    }

    private func resolveConfig(_ options: [String: NSObject]?) throws -> String {
        if let passed = options?["config"] as? String, !passed.isEmpty {
            return passed
        }
        if let fileContent = try? String(contentsOf: FilePath.configURL, encoding: .utf8), !fileContent.isEmpty {
            return fileContent
        }
        throw TunnelError("missing config")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("stopping, reason: \(reason.rawValue)")
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
        bridge = nil
    }

    func stopService() {
        try? commandServer?.closeService()
        bridge?.reset()
    }

    func writeMessage(_ message: String) {
        commandServer?.writeMessage(2, message: message)
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }

    /// Hot-reload the running service with a new config pushed from the app.
    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let config = String(data: messageData, encoding: .utf8), !config.isEmpty else {
            return nil
        }
        do {
            let override = LibboxOverrideOptions()
            try commandServer?.startOrReloadService(config, options: override)
            return nil
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }
}
