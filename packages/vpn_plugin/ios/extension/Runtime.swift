import Foundation

/// Shared identifiers. The App Group is read from the extension's Info.plist
/// (key `SingboxVpnAppGroup`, set up by tool/add_extension_target.rb) so it
/// matches the host app's group — DO NOT hardcode it.
enum AppGroup {
    static var id: String {
        if let g = Bundle.main.object(forInfoDictionaryKey: "SingboxVpnAppGroup") as? String, !g.isEmpty {
            return g
        }
        // Fallback: derive the app group from the extension bundle id.
        let bundle = Bundle.main.bundleIdentifier ?? "app"
        let app = bundle.replacingOccurrences(of: ".SingboxTunnel", with: "")
        return "group.\(app)"
    }

    static let configFileName = "config.json"
    static let logFileName = "box.log"
}

/// File locations inside the shared App Group container (same path in the app
/// and in the extension process).
enum FilePath {
    static var sharedDirectory: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)!
    }

    static var workingDirectory: URL {
        let url = sharedDirectory.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var cacheDirectory: URL {
        let url = sharedDirectory.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var configURL: URL { sharedDirectory.appendingPathComponent(AppGroup.configFileName) }
    static var logURL: URL { sharedDirectory.appendingPathComponent(AppGroup.logFileName) }
    static var extLogURL: URL { sharedDirectory.appendingPathComponent("ext.log") }
}

/// Append one diagnostic line to the extension log (read back by the app).
func extLog(_ message: String) {
    let line = "[ext] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = FilePath.extLogURL
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    } else {
        try? data.write(to: url)
    }
}

func extLogReset() {
    try? Data().write(to: FilePath.extLogURL)
}

struct TunnelError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Run an async operation synchronously — used inside synchronous gomobile
/// callbacks (e.g. openTun) that must return a value to the Go side.
func runBlocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        do { resultBox.value = .success(try await operation()) }
        catch { resultBox.value = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    switch resultBox.value! {
    case let .success(value): return value
    case let .failure(error): throw error
    }
}

func runBlocking<T>(_ operation: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        resultBox.value = .success(await operation())
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(value) = resultBox.value! { return value }
    fatalError("unreachable")
}

private final class ResultBox<T> {
    var value: Result<T, Error>?
}
