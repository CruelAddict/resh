import CoreFoundation
import Darwin
import Foundation
import ReshCore

struct LauncherRequest: Codable, Sendable {
    var operation = "show"
    var client: String?
    var currentSessionID: String?
    var server: String?
    var config: String?
    var debug: Bool?
    var path: String?
    var cwd: String?
    var action: KeyInvocation?

    var changesSession: Bool { operation == "connect" || operation == "last" }
}

struct LauncherCommands {
    let service: ReshService
    let configuration: ReshConfiguration
    var sessions: [Candidate] = []

    func run(_ request: LauncherRequest) async throws -> [String: Any] {
        let service = service.at(RexTarget(clientID: request.client, server: request.server ?? service.target.server))
        var current: Candidate?
        if let id = request.currentSessionID {
            current = try await Task.detached { try service.session(id, candidates: sessions) }.value
        }
        switch request.operation {
        case "last":
            guard let id = try await service.connectLast(from: current) else { return [:] }
            return ["session_id": id]
        case "connect":
            guard let path = request.path, let cwd = request.cwd else { throw ReshError("The folder and calling directory are required.") }
            let result = try await service.connect(path, configuration: configuration, cwd: cwd, from: current)
            return ["session_id": result.sessionID, "path": result.path]
        default:
            throw ReshError("Unknown session command: \(request.operation)")
        }
    }
}

/// A small Foundation-only sender talks to the already-running native panel.
/// No session list is stored here or on disk.
enum LauncherIPC {
    static var name: CFString { "io.github.CruelAddict.resh.panel.\(getuid())" as CFString }

    static func send(_ request: LauncherRequest, name: CFString = LauncherIPC.name) throws -> [String: Any]? {
        guard let port = CFMessagePortCreateRemote(nil, name) else { return nil }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 1, try JSONEncoder().encode(request) as CFData,
            1, request.changesSession ? 60 : 3, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() else {
            if request.changesSession {
                throw ReshError("The resh service did not return the session command's result (\(status)). It may have completed; the command was not retried.")
            }
            throw ReshError("The resh panel did not acknowledge the request (\(status)).")
        }
        let response = try JSONSerialization.jsonObject(with: data as Data) as? [String: Any] ?? [:]
        if let error = response["error"] as? String { throw ReshError(error) }
        return response
    }

    static func launchHost(configurationPath: String?, restart: Bool = false, debug: Bool = false) throws {
        try ServiceLauncher().start(executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
            configurationPath: configurationPath, restart: restart, debug: debug)
    }
}

private final class LauncherReply: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var data: Data?

    func finish(_ response: [String: Any]) {
        data = try? JSONSerialization.data(withJSONObject: response)
        ready.signal()
    }

    func wait() -> Data? { ready.wait(); return data }
}

@MainActor
final class LauncherHost {
    private var port: CFMessagePort?
    private let queue = DispatchQueue(label: "resh.launcher")
    var onRequest: ((LauncherRequest) async -> [String: Any])?

    init(name: CFString = LauncherIPC.name) throws {
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, name, { _, _, data, info in
            guard let data, let info else { return nil }
            let host = Unmanaged<LauncherHost>.fromOpaque(info).takeUnretainedValue()
            let reply = LauncherReply()
            let payload = data as Data
            Task { @MainActor in
                let response: [String: Any]
                do {
                    let request = try JSONDecoder().decode(LauncherRequest.self, from: payload)
                    response = await host.onRequest?(request) ?? ["error": "Panel is not ready."]
                } catch { response = ["error": error.localizedDescription] }
                reply.finish(response)
            }
            guard let data = reply.wait() else { return nil }
            return Unmanaged.passRetained(data as CFData)
        }, &context, nil)
        guard let port else { throw ReshError("Another resh host is already running.") }
        // Waiting for a command's result must not block the AppKit run loop.
        CFMessagePortSetDispatchQueue(port, queue)
    }

    func stop() {
        if let port { CFMessagePortInvalidate(port) }
        port = nil
    }
}
