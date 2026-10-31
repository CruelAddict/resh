import Foundation
import ReshCore
import Testing
@testable import Resh

@Suite("Picker behavior", .serialized)
struct PickerTests {}

extension RexTheme {
    static var fixture: RexTheme {
        .fallback(systemIsDark: true)
    }
}

extension KeyboardLayouts {
    static let fixture = KeyboardLayouts([
        "qwertyuiop[]asdfghjkl;'zxcvbnm,./`",
        "йцукенгшщзхъфывапролджэячсмитьбю.ё",
        "qwertzuiopü+asdfghjklöäyxcvbnm,.-^",
    ].map { ($0 + $0.uppercased()).map(String.init) })
}

final class SnapshotStub: RexSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<RexSnapshot, Error>]
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(_ responses: [Result<RexSnapshot, Error>]) { self.responses = responses }

    func snapshot(target: RexTarget, rexAppPID: Int32?) throws -> RexSnapshot {
        lock.lock(); defer { lock.unlock() }
        count += 1
        guard !responses.isEmpty else { throw ReshError("Unexpected snapshot request") }
        return try responses.removeFirst().get()
    }
}

final class RexBridgeStub: CommandRunning, @unchecked Sendable {
    let directory: URL
    let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
    private let lock = NSLock()
    private var hosts: [RexHost] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("resh-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func setHosts(_ hosts: [RexHost]) {
        lock.lock(); defer { lock.unlock() }
        self.hosts = hosts
    }

    func openTransport(server: String) -> any RexDataTransport {
        lock.lock(); defer { lock.unlock() }
        let endpoint = hosts.first { $0.server == server }?.endpoints.first ?? server
        return Transport(endpoint: endpoint)
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, directory: String?) throws -> CommandResult {
        guard executable == tools.rex, arguments.contains("hosts") else { throw ReshError("Unexpected command: \(arguments)") }
        lock.lock(); defer { lock.unlock() }
        return CommandResult(stdout: try JSONSerialization.data(withJSONObject: [
            "hosts": hosts.map { ["host": ["id": $0.id, "label": $0.label, "endpoints": $0.endpoints]] },
        ]))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private final class Transport: RexDataTransport, @unchecked Sendable {
        private let endpoint: String
        private let lock = NSLock()
        private var running = true
        private var attached = false
        private var responses = [Data("{\"ready\":true}\n".utf8)]
        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

        init(endpoint: String) { self.endpoint = endpoint }

        func write(_ data: Data) throws -> Int {
            lock.lock(); defer { lock.unlock() }
            guard running else { return 0 }
            let request = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try #require(request["method"] as? String)
            let args = request["args"] as? [String: Any] ?? [:]
            let response: [String: Any]
            switch method {
            case "session.attach_all":
                attached = true
                response = ["result": ["sessions": []]]
            case "client.list":
                response = ["result": ["clients": [["client_id": "client:test", "info": ["kind": "app", "platform": "macos"]]]]]
            case "session.create":
                let label = try #require(args["label"] as? String)
                response = ["result": ["session_id": endpoint + "/" + label]]
            case "client.perform":
                response = ["result": ["performed_by": try #require(args["client_id"] as? String)]]
            case "session.focus_block":
                response = attached ? ["result": ["revision": 1]] : ["error": "stream is not attached to session"]
            default:
                throw ReshError("Unexpected method: \(method)")
            }
            var reply = try JSONSerialization.data(withJSONObject: response)
            reply.append(10)
            responses.append(reply)
            return data.count
        }

        func read(timeout: TimeInterval) throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            guard running else { return Data() }
            guard !responses.isEmpty else { throw ReshError("Unexpected bridge read without a response.") }
            return responses.removeFirst()
        }

        func stop() { lock.lock(); defer { lock.unlock() }; running = false }
    }
}
