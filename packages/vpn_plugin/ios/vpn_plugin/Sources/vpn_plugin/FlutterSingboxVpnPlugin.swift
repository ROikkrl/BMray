import Flutter
import Foundation
import NetworkExtension

/// App-side bridge: registers the Flutter channels and drives the
/// NETunnelProviderManager. The sing-box core itself runs in the host app's
/// PacketTunnel extension target (added via tool/add_extension_target.rb).
///
/// Host-specific identifiers are read from the app's Info.plist:
///   SingboxVpnAppGroup       -> e.g. group.com.example.app  (shared with the extension)
///   SingboxVpnTunnelBundleId -> e.g. com.example.app.SingboxTunnel
public class FlutterSingboxVpnPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  private var eventSink: FlutterEventSink?
  private var manager: NETunnelProviderManager?
  private var statusObserver: NSObjectProtocol?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterSingboxVpnPlugin()
    let methods = FlutterMethodChannel(name: "flutter_singbox_vpn/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(name: "flutter_singbox_vpn/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    Task { await instance.prepare() }
  }

  // MARK: - Host configuration

  private var appGroup: String {
    if let g = Bundle.main.object(forInfoDictionaryKey: "SingboxVpnAppGroup") as? String, !g.isEmpty { return g }
    return "group.\(Bundle.main.bundleIdentifier ?? "app")"
  }

  private var tunnelBundleId: String {
    if let t = Bundle.main.object(forInfoDictionaryKey: "SingboxVpnTunnelBundleId") as? String, !t.isEmpty { return t }
    return "\(Bundle.main.bundleIdentifier ?? "app").SingboxTunnel"
  }

  private var sharedDir: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }
  private var configURL: URL? { sharedDir?.appendingPathComponent("config.json") }
  private var logURL: URL? { sharedDir?.appendingPathComponent("box.log") }

  // MARK: - FlutterPlugin

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let args = call.arguments as? [String: Any]
      let config = args?["config"] as? String ?? ""
      let name = args?["name"] as? String ?? "sing-box"
      Task {
        do { try await self.connect(config: config, name: name); result(nil) }
        catch { result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil)) }
      }
    case "stop":
      Task { await self.disconnect(); result(nil) }
    case "status":
      result(["state": currentStateString()])
    case "coreVersion":
      result("sing-box")
    case "validateConfig":
      result(nil) // the extension validates at start
    case "readLogs":
      result(readLogs())
    case "clearLogs":
      clearLogs(); result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - FlutterStreamHandler

  public func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    pushStatus()
    return nil
  }

  public func onCancel(withArguments _: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Tunnel control

  private func prepare() async {
    manager = try? await currentManager()
    observeStatus()
    pushStatus()
  }

  private func connect(config rawConfig: String, name: String) async throws {
    guard !rawConfig.isEmpty else {
      throw NSError(domain: "SingboxVpn", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty config"])
    }
    guard let logURL, let configURL else {
      throw NSError(domain: "SingboxVpn", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "App Group unavailable — check SingboxVpnAppGroup + entitlements"])
    }
    let configStr = injectLogOutput(rawConfig, logPath: logURL.path)
    try configStr.write(to: configURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: configURL.path
    )

    let mgr = try await currentManager() ?? NETunnelProviderManager()
    let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
    proto.providerBundleIdentifier = tunnelBundleId
    proto.serverAddress = name.isEmpty ? "sing-box" : name
    mgr.protocolConfiguration = proto
    mgr.localizedDescription = name.isEmpty ? "sing-box" : name
    mgr.isEnabled = true

    mgr.isOnDemandEnabled = false

    try await mgr.saveToPreferences()
    try await mgr.loadFromPreferences()
    manager = mgr
    observeStatus()
    try mgr.connection.startVPNTunnel(options: ["config": configStr as NSString])
  }

  private func disconnect() async {
    defer {
      if let configURL { try? FileManager.default.removeItem(at: configURL) }
    }
    guard let mgr = try? await currentManager() else { return }
    if mgr.isOnDemandEnabled {
      mgr.isOnDemandEnabled = false
      try? await mgr.saveToPreferences()
    }
    mgr.connection.stopVPNTunnel()
  }

  private func currentManager() async throws -> NETunnelProviderManager? {
    try await NETunnelProviderManager.loadAllFromPreferences().first {
      ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleId
    }
  }

  // MARK: - Status

  private func observeStatus() {
    if let observer = statusObserver { NotificationCenter.default.removeObserver(observer); statusObserver = nil }
    guard let connection = manager?.connection else { return }
    statusObserver = NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: connection, queue: .main
    ) { [weak self] _ in self?.pushStatus() }
  }

  private func currentStateString() -> String {
    switch manager?.connection.status {
    case .connected: return "connected"
    case .connecting: return "connecting"
    case .disconnecting: return "disconnecting"
    case .reasserting: return "reasserting"
    case .disconnected, .invalid, .none: return "disconnected"
    @unknown default: return "disconnected"
    }
  }

  private func pushStatus() {
    let state = currentStateString()
    eventSink?(["state": state])
    if state == "disconnected", #available(iOS 16.0, *), let conn = manager?.connection {
      conn.fetchLastDisconnectError { [weak self] err in
        guard let err else { return }
        DispatchQueue.main.async { self?.eventSink?(["state": "disconnected", "message": err.localizedDescription]) }
      }
    }
  }

  // MARK: - Logs / config

  private func readLogs() -> String {
    guard let dir = sharedDir else { return "" }
    func tail(_ relative: String, _ maxBytes: Int) -> String {
      guard let data = try? Data(contentsOf: dir.appendingPathComponent(relative)), !data.isEmpty else { return "" }
      let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
      return String(data: Data(slice), encoding: .utf8) ?? ""
    }
    var out = ""
    let ext = tail("ext.log", 16 * 1024)
    if !ext.isEmpty { out += "===== extension =====\n\(ext)\n" }
    let stderr = tail("cache/stderr.log", 16 * 1024)
    if !stderr.isEmpty { out += "===== stderr =====\n\(stderr)\n" }
    let box = tail("box.log", 48 * 1024)
    if !box.isEmpty { out += "===== sing-box =====\n\(box)" }
    return out
  }

  private func clearLogs() {
    guard let dir = sharedDir else { return }
    for f in ["ext.log", "cache/stderr.log", "box.log"] {
      try? Data().write(to: dir.appendingPathComponent(f))
    }
  }

  private func injectLogOutput(_ raw: String, logPath: String) -> String {
    guard let data = raw.data(using: .utf8),
          var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return raw }
    var log = (obj["log"] as? [String: Any]) ?? [:]
    log["output"] = logPath
    log["disabled"] = false
    obj["log"] = log
    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
          let str = String(data: out, encoding: .utf8) else { return raw }
    return str
  }
}
