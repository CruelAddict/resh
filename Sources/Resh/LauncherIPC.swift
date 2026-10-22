import CoreFoundation
import Darwin
import Foundation
import ReshCore

struct LauncherRequest: Codable {
    var operation = "show"
    var client: String?
    var session: String?
    var server: String?
    var sessions: [RexSession]?
    var smokeTest: String?
    var sentAt = ProcessInfo.processInfo.systemUptime
}

/// A small Foundation-only sender talks to the already-running native panel.
/// No session list is stored here or on disk.
enum LauncherIPC {
    static var name: CFString { "io.github.CruelAddict.resh.panel.\(getuid())" as CFString }

    static func send(_ request: LauncherRequest) throws -> [String: Any]? {
        guard let port = CFMessagePortCreateRemote(nil, name) else { return nil }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 1, try JSONEncoder().encode(request) as CFData,
            1, 3, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() else {
            throw ReshError("The resh panel did not acknowledge the request (\(status)).")
        }
        let response = try JSONSerialization.jsonObject(with: data as Data) as? [String: Any] ?? [:]
        if let error = response["error"] as? String { throw ReshError(error) }
        return response
    }

    static func launchHost() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--standby"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

@MainActor
final class LauncherHost {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    var onRequest: ((LauncherRequest) -> [String: Any])?

    init() throws {
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, LauncherIPC.name, { _, _, data, info in
            guard let data, let info else { return nil }
            let host = Unmanaged<LauncherHost>.fromOpaque(info).takeUnretainedValue()
            let response: [String: Any]
            do {
                let request = try JSONDecoder().decode(LauncherRequest.self, from: data as Data)
                response = MainActor.assumeIsolated { host.onRequest?(request) ?? ["error": "Panel is not ready."] }
            } catch { response = ["error": error.localizedDescription] }
            guard let reply = try? JSONSerialization.data(withJSONObject: response) else { return nil }
            return Unmanaged.passRetained(reply as CFData)
        }, &context, nil)
        guard let port else { throw ReshError("Another resh host is already running.") }
        source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        source = nil; port = nil
    }
}
