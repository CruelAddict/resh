import Foundation

public struct RexTarget: Codable, Sendable {
    public var clientID: String?
    public var server: String
    public init(clientID: String? = nil, server: String? = nil) {
        self.clientID = clientID
        let socket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/rex/server.sock")
        self.server = server ?? socket.absoluteString.replacingOccurrences(of: "file://", with: "unix://")
    }
}

public struct RexSession: Codable, Sendable {
    public let sessionID: String
    public let label: String
    public init(sessionID: String, label: String) { self.sessionID = sessionID; self.label = label }
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", label }
}

public protocol RexAPICalling: Sendable {
    func updateHosts(_ hosts: [RexHost])
    func call(_ method: String, arguments: Data, server: String, timeout: TimeInterval) throws -> Data
}

public struct RexClient: Sendable {
    public let tools: Tools
    public let target: RexTarget
    public let runner: any CommandRunning
    public let apiCaller: (any RexAPICalling)?
    public init(tools: Tools, target: RexTarget, runner: any CommandRunning = SystemCommandRunner(), apiCaller: (any RexAPICalling)? = nil) {
        self.tools = tools; self.target = target; self.runner = runner; self.apiCaller = apiCaller
    }

    public func at(_ target: RexTarget) -> RexClient {
        RexClient(tools: tools, target: target, runner: runner, apiCaller: apiCaller)
    }

    public func at(_ host: RexHost) -> RexClient {
        at(RexTarget(server: host.server))
    }

    public func command(_ arguments: [String], timeout: TimeInterval = 5) throws -> Data {
        let operation = arguments.prefix { $0 != "--args" && !$0.hasPrefix("{") }.joined(separator: " ")
        DebugLog.shared.record(operation, source: "rex:\(target.server)")
        let result = try runner.run(tools.rex,
            ["--autostart=false", "--timeout", "\(timeout)s", "--server", target.server] + arguments, timeout: timeout)
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let error = ReshError(message.isEmpty ? "Rex command failed (\(result.status))." : message,
                userMessage: Self.userMessage(for: message, operation: operation))
            DebugLog.shared.record(error, source: "rex:\(target.server):\(operation)")
            throw error
        }
        return result.stdout
    }

    // Only recognized, actionable refusals belong in the picker, never arbitrary stderr.
    private static func userMessage(for message: String, operation: String) -> String? {
        let text = message.lowercased()
        if operation.contains("do session.select"), text.contains("remote control"), text.contains("disabled") || text.contains("enable") {
            return "Enable Remote Control in Rex Settings → Rex Server to switch sessions."
        }
        if operation == "api call session.create",
           text.contains("too many sessions") || text.contains("session limit") || text.contains("maximum number of sessions") {
            return "Rex’s session limit has been reached. Close a session before creating another."
        }
        return nil
    }
    public func api(_ method: String, _ arguments: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        if let apiCaller {
            let started = ProcessInfo.processInfo.systemUptime
            defer { DebugLog.shared.record("\(method): \((ProcessInfo.processInfo.systemUptime - started) * 1000) ms", source: "rex:\(target.server)") }
            do { return try apiCaller.call(method, arguments: data, server: target.server, timeout: 5) }
            catch {
                let message = error.localizedDescription
                throw ReshError(message, userMessage: Self.userMessage(for: message, operation: "api call " + method)
                    ?? (error as? ReshError)?.userMessage)
            }
        }
        let json = String(decoding: data, as: UTF8.self)
        return try command(["api", "call", method, json])
    }
    public func sessions(timeout: TimeInterval = 5) throws -> [RexSession] {
        let data = try apiCaller?.call("session.list", arguments: Data("{}".utf8), server: target.server, timeout: timeout)
            ?? command(["ls", "--json"], timeout: timeout)
        let reply = try JSONDecoder().decode([String: [RexSession]?].self, from: data)
        guard let sessions = reply["sessions"] else { throw ReshError("Rex returned an invalid session list.") }
        return sessions ?? []
    }
    public func resolveClient() throws -> (id: String, rexAppPID: Int32?) {
        let data = try apiCaller == nil ? command(["client", "list", "--json"]) : api("client.list", [:])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let clients = (json?["clients"] as? [[String: Any]] ?? []).filter {
            let info = $0["info"] as? [String: Any]
            return info?["kind"] as? String == "app" && info?["platform"] as? String == "macos"
        }
        let selected: [String: Any]?
        if let requested = target.clientID { selected = clients.first { $0["client_id"] as? String == requested } }
        else { selected = clients.count == 1 ? clients.first : nil }
        guard let selected, let id = selected["client_id"] as? String else {
            throw ReshError("Cannot identify the Rex app. Open resh from ⌘S in Rex, or pass --client CLIENT_ID.")
        }
        return (id, (selected["principal"] as? [String: Any])?["pid"] as? Int32)
    }
    public func select(_ sessionID: String, clientID: String, windowID: String? = nil) throws {
        var values = ["session_id": sessionID]
        if let windowID { values["window_id"] = windowID }
        if apiCaller != nil {
            do {
                _ = try api("client.perform", ["client_id": clientID, "action": "session.select", "args": values, "timeout_ms": 5000])
            } catch {
                let message = error.localizedDescription
                throw ReshError(message, userMessage: Self.userMessage(for: message, operation: "do session.select")
                    ?? (error as? ReshError)?.userMessage)
            }
            return
        }
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
        _ = try command(["-C", clientID, "do", "session.select", "--args", arguments, "--json"])
    }
}
