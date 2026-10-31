import Foundation
import Darwin
import ReshCore

struct RexSnapshot: Decodable, Sendable {
    let client: String
    let rexAppPID: Int32
    let sessions: [RexSession]

    init(client: String, rexAppPID: Int32, sessions: [RexSession]) {
        self.client = client; self.rexAppPID = rexAppPID; self.sessions = sessions
    }
    private enum CodingKeys: String, CodingKey { case client, rexAppPID = "rex_app_pid", sessions }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        client = try values.decode(String.self, forKey: .client)
        rexAppPID = try values.decode(Int32.self, forKey: .rexAppPID)
        sessions = try values.decodeIfPresent([RexSession].self, forKey: .sessions) ?? []
    }
}

protocol RexSnapshotProviding: Sendable {
    func snapshot(target: RexTarget, rexAppPID: Int32?) throws -> RexSnapshot
}

/// Rex reports a lost server connection as a Lua API error while keeping the
/// script's stdin/stdout alive. Do not confuse that with an application error.
func isRexTransportFailure(_ message: String) -> Bool {
    message.contains("reading API control:") || message.hasPrefix("server went away:")
        || message.contains("dial unix ") || message.contains("connection reset by peer")
        || message == "EOF" || message == "unexpected EOF"
}

protocol RexDataTransport: Sendable {
    var isRunning: Bool { get }
    func write(_ data: Data) throws -> Int
    /// nil means no data is ready; an empty chunk means EOF.
    func read(timeout: TimeInterval) throws -> Data?
    func stop()
}

private final class RexDataProcess: RexDataTransport, @unchecked Sendable {
    private let process: RexProcess
    var isRunning: Bool { process.isRunning }

    init(tools: Tools, server: String) throws {
        guard let script = Bundle.module.url(forResource: "resh-data", withExtension: "lua") else {
            throw ReshError("Missing bundled resource: resh-data.lua. Reinstall resh.")
        }
        process = try RexProcess(executable: tools.rex,
            arguments: ["--autostart=false", "--server", server, "do", script.path], pipeInput: true)
    }

    func write(_ data: Data) throws -> Int {
        guard let input = process.input else { return 0 }
        return data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
    }

    func read(timeout: TimeInterval) throws -> Data? {
        let output = process.output
        var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&descriptor, 1, Int32(timeout * 1000))
        if ready < 0, errno == EINTR { return nil }
        if ready == 0 { return nil }
        guard ready > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // FileHandle.read(upToCount:) tries to fill the requested length on a pipe.
        // A POSIX read returns available bytes immediately, without waiting for EOF.
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { return nil }
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Data(chunk.prefix(count))
    }

    func stop() { process.stop() }
}

/// One supported CLI request/reply connection per server, shared by snapshots
/// and session operations. Only reads may be retried after a lost reply.
final class RexDataConnection: RexSnapshotProviding, RexAPICalling, @unchecked Sendable {
    private final class Connection {
        let transport: any RexDataTransport
        let server: String
        var buffer = Data() // Only the request lock may access the buffer.
        init(transport: any RexDataTransport, server: String) { self.transport = transport; self.server = server }
    }
    private struct ClosedConnection: Error {}
    private struct ConnectionTimeout: Error {}
    private struct RequestFailure: Error { let message: String }
    private let openTransport: @Sendable (String) throws -> any RexDataTransport
    private let timeout: TimeInterval
    private let requests = NSLock()
    private let state = NSLock()
    private var connections: [String: Connection] = [:]
    private var hosts: [String: RexHost] = [:]
    private var generation = 0
    init(tools: Tools, timeout: TimeInterval = 5,
         openTransport: (@Sendable (String) throws -> any RexDataTransport)? = nil) {
        self.openTransport = openTransport ?? { try RexDataProcess(tools: tools, server: $0) }
        self.timeout = timeout
    }
    deinit { stop() }

    func updateHosts(_ hosts: [RexHost]) {
        let updated = Dictionary(hosts.map { ($0.server, $0) }, uniquingKeysWith: { first, _ in first })
        // Serialize with requests so a connection being opened cannot repopulate
        // the cache with an old endpoint after invalidation.
        requests.lock(); defer { requests.unlock() }
        state.lock()
        let old = connections.keys.filter { self.hosts[$0] != updated[$0] }
            .compactMap { connections.removeValue(forKey: $0) }
        self.hosts = updated
        state.unlock()
        for connection in old { connection.transport.stop() }
    }

    func snapshot(target: RexTarget, rexAppPID: Int32? = nil) throws -> RexSnapshot {
        guard target.clientID != nil || rexAppPID != nil else {
            throw ReshError("Open resh while Rex is the active app, or pass --client CLIENT_ID.")
        }
        var arguments: [String: Any] = [:]
        if let client = target.clientID { arguments["client"] = client }
        else if let rexAppPID { arguments["rex_app_pid"] = rexAppPID }
        let response = try request(arguments, server: target.server, timeout: timeout, retryRead: true)
        return try JSONDecoder().decode(RexSnapshot.self, from: response)
    }

    func call(_ method: String, arguments: Data, server: String, timeout: TimeInterval) throws -> Data {
        let args = try JSONSerialization.jsonObject(with: arguments)
        let response = try request(["method": method, "args": args], server: server, timeout: timeout, retryRead: false)
        let value = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        var result = value?["result"] ?? NSNull()
        // Lua encodes empty tables as objects and drops null fields. Restore
        // session.list's array so an empty Rex server can create its first session.
        if method == "session.list", var listed = result as? [String: Any],
           listed["sessions"] == nil || (listed["sessions"] as? [String: Any])?.isEmpty == true {
            listed["sessions"] = [Any]()
            result = listed
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    func prepare(server: String) {
        let request = currentGeneration()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            requests.lock(); defer { requests.unlock() }
            do {
                _ = try startIfNeeded(server: server, request: request,
                    deadline: ProcessInfo.processInfo.systemUptime + timeout)
            } catch {
                if !(error is CancellationError) { DebugLog.shared.record(error, source: "rex:prepare") }
            }
        }
    }

    private func request(_ arguments: [String: Any], server: String, timeout: TimeInterval, retryRead: Bool) throws -> Data {
        let request = currentGeneration()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        requests.lock(); defer { requests.unlock() }
        var retryDelay: TimeInterval = 0
        while true {
            var sent = false
            do {
                let connection = try startIfNeeded(server: server, request: request, deadline: deadline)
                var data = try JSONSerialization.data(withJSONObject: arguments)
                data.append(10)
                try check(request)
                let written = try connection.transport.write(data)
                sent = written > 0
                guard written == data.count else { throw ClosedConnection() }
                let response = try readLine(connection, request: request, deadline: deadline)
                try check(request)
                if let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                   let error = object["error"] as? String {
                    // Rex.app can register a little after the restarted server
                    // starts accepting connections. Keep the same native opening.
                    let waitingForApp = retryDelay > 0 && arguments["rex_app_pid"] != nil && arguments["client"] == nil
                        && error.hasPrefix("Cannot find the requested Rex app.")
                    if isRexTransportFailure(error) || waitingForApp { throw ClosedConnection() }
                    throw RequestFailure(message: error)
                }
                return response
            } catch let error as RequestFailure {
                throw ReshError(error.message)
            } catch {
                discard(server: server, request: request)
                try check(request)
                if !retryRead {
                    if sent {
                        throw ReshError("Rex did not confirm the request. It may have completed; the request was not retried.\n\(error.localizedDescription)",
                            userMessage: "Rex didn’t confirm the operation. Check Rex before trying again.")
                    }
                    if error is ClosedConnection || error is ConnectionTimeout { throw ReshError("Can’t connect to Rex.") }
                    throw error
                }
                if error is ConnectionTimeout { throw ReshError("Can’t connect to Rex.") }
                if error is ClosedConnection {
                    let retryAt = min(deadline, ProcessInfo.processInfo.systemUptime + retryDelay)
                    while ProcessInfo.processInfo.systemUptime < retryAt {
                        try check(request)
                        Thread.sleep(forTimeInterval: max(0, min(0.05, retryAt - ProcessInfo.processInfo.systemUptime)))
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw ReshError("Can’t connect to Rex.") }
                    retryDelay = retryDelay == 0 ? 0.1 : min(1, retryDelay * 2)
                    continue
                }
                throw error
            }
        }
    }

    private func startIfNeeded(server: String, request: Int, deadline: TimeInterval) throws -> Connection {
        try check(request)
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ConnectionTimeout() }
        state.lock(); let existing = connections[server]; state.unlock()
        if let existing, existing.transport.isRunning { return existing }
        discard(server: server, request: request)
        let transport = try openTransport(server)
        let created = Connection(transport: transport, server: server)
        state.lock()
        let cancelled = generation != request
        if !cancelled { connections[server] = created }
        state.unlock()
        if cancelled { transport.stop(); throw CancellationError() }
        do {
            let hello = try JSONSerialization.jsonObject(with: readLine(created, request: request, deadline: deadline)) as? [String: Any]
            guard hello?["ready"] as? Bool == true else { throw ReshError("Invalid Rex data connection handshake.") }
            try check(request)
            // Session-scoped calls need attachment on this same stream. Observe
            // all sessions without joining them or taking ownership of panes.
            let bootstrap: [String: Any] = ["method": "session.attach_all", "args": ["event_scope": "session"]]
            var data = try JSONSerialization.data(withJSONObject: bootstrap)
            data.append(10)
            let written = try transport.write(data)
            guard written == data.count else { throw ClosedConnection() }
            let response = try JSONSerialization.jsonObject(with: readLine(created, request: request, deadline: deadline)) as? [String: Any]
            if let error = response?["error"] as? String {
                if isRexTransportFailure(error) { throw ClosedConnection() }
                throw ReshError(error)
            }
            guard response?["result"] != nil else { throw ReshError("Invalid Rex session attachment reply.") }
            try check(request)
            return created
        } catch { discard(server: server, request: request); throw error }
    }

    private func readLine(_ connection: Connection, request: Int, deadline: TimeInterval) throws -> Data {
        while true {
            try check(request)
            if let newline = connection.buffer.firstIndex(of: 10) {
                let line = Data(connection.buffer[..<newline])
                connection.buffer.removeSubrange(...newline)
                return line
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ConnectionTimeout() }
            guard let chunk = try connection.transport.read(timeout: min(remaining, 0.1)) else { continue }
            if chunk.isEmpty { throw ClosedConnection() }
            connection.buffer.append(chunk)
            guard connection.buffer.count <= 8 * 1024 * 1024 else { throw ReshError("The Rex snapshot is too large.") }
        }
    }

    private func currentGeneration() -> Int { state.lock(); defer { state.unlock() }; return generation }
    private func check(_ request: Int) throws {
        if currentGeneration() != request || Task.isCancelled { throw CancellationError() }
    }
    private func discard(server: String, request: Int) {
        state.lock()
        let old = generation == request ? connections.removeValue(forKey: server) : nil
        state.unlock()
        old?.transport.stop()
    }
    func stop() {
        state.lock()
        generation += 1
        let old = Array(connections.values); connections = [:]
        state.unlock()
        for connection in old { connection.transport.stop() }
    }

    /// Shutdown barrier, only used off the UI thread after stop().
    func waitUntilStopped() { requests.lock(); requests.unlock() }
}
