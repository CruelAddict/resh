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

/// Request/reply bridge for cold openings, explicit reloads and diagnostics.
/// Normal openings use SessionStore, without issuing a new request.
final class RexDataConnection: RexSnapshotProviding, @unchecked Sendable {
    private final class Connection {
        let process: RexProcess
        let server: String
        var buffer = Data() // Only the request lock may access the buffer.
        init(process: RexProcess, server: String) { self.process = process; self.server = server }
    }
    private struct ClosedConnection: Error {}
    private struct ConnectionTimeout: Error {}
    private let tools: Tools
    private let timeout: TimeInterval
    private let requests = NSLock()
    private let state = NSLock()
    private var connection: Connection?
    private var generation = 0
    init(tools: Tools, timeout: TimeInterval = 5) { self.tools = tools; self.timeout = timeout }
    deinit { stop() }

    func snapshot(target: RexTarget, rexAppPID: Int32? = nil) throws -> RexSnapshot {
        let request = currentGeneration()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        requests.lock(); defer { requests.unlock() }
        guard target.clientID != nil || rexAppPID != nil else {
            throw ReshError("Open resh while Rex is the active app, or pass --client CLIENT_ID.")
        }
        // Only reads are retried, within one total deadline including reconnects.
        // The first retry is immediate; further failures back off while Rex starts.
        var retryDelay: TimeInterval = 0
        while true {
            do {
                let connection = try startIfNeeded(server: target.server, request: request, deadline: deadline)
                var arguments: [String: Any] = [:]
                if let client = target.clientID { arguments["client"] = client }
                else if let rexAppPID { arguments["rex_app_pid"] = rexAppPID }
                var data = try JSONSerialization.data(withJSONObject: arguments)
                data.append(10)
                try check(request)
                guard let input = connection.process.input else { throw ClosedConnection() }
                let written = data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
                guard written == data.count else { throw ClosedConnection() }
                let response = try readLine(connection, request: request, deadline: deadline)
                try check(request)
                if let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                   let error = object["error"] as? String {
                    // Rex.app can register a little after the restarted server
                    // starts accepting connections. Keep the same native opening.
                    let waitingForApp = retryDelay > 0 && rexAppPID != nil && target.clientID == nil
                        && error.hasPrefix("Cannot find the requested Rex app.")
                    if isRexTransportFailure(error) || waitingForApp { throw ClosedConnection() }
                    throw ReshError(error)
                }
                return try JSONDecoder().decode(RexSnapshot.self, from: response)
            } catch {
                discard(request: request)
                try check(request)
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
        state.lock(); let existing = connection; state.unlock()
        if let existing, existing.process.isRunning, existing.server == server { return existing }
        discard(request: request)
        guard let script = Bundle.module.url(forResource: "resh-data", withExtension: "lua") else {
            throw ReshError("Missing bundled resource: resh-data.lua. Reinstall resh.")
        }
        let child = try RexProcess(executable: tools.rex,
            arguments: ["--autostart=false", "--server", server, "do", script.path], pipeInput: true)
        let created = Connection(process: child, server: server)
        state.lock()
        let cancelled = generation != request
        if !cancelled { connection = created }
        state.unlock()
        if cancelled { child.stop(); throw CancellationError() }
        do {
            let hello = try JSONSerialization.jsonObject(with: readLine(created, request: request, deadline: deadline)) as? [String: Any]
            guard hello?["ready"] as? Bool == true else { throw ReshError("Invalid Rex data connection handshake.") }
            try check(request)
            return created
        } catch { discard(request: request); throw error }
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
            let output = connection.process.output
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining, 0.1) * 1000))
            if ready < 0, errno == EINTR { continue }
            if ready == 0 { continue }
            guard ready > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // FileHandle.read(upToCount:) tries to fill the requested length on a pipe.
            // A POSIX read returns the available response immediately, without waiting for EOF.
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { throw ClosedConnection() }
            connection.buffer.append(contentsOf: chunk.prefix(count))
            guard connection.buffer.count <= 8 * 1024 * 1024 else { throw ReshError("The Rex snapshot is too large.") }
        }
    }

    private func currentGeneration() -> Int { state.lock(); defer { state.unlock() }; return generation }
    private func check(_ request: Int) throws {
        if currentGeneration() != request || Task.isCancelled { throw CancellationError() }
    }
    private func discard(request: Int) {
        state.lock()
        let old = generation == request ? connection : nil
        if generation == request { connection = nil }
        state.unlock()
        old?.process.stop()
    }
    func stop() {
        state.lock()
        generation += 1
        let old = connection; connection = nil
        state.unlock()
        old?.process.stop()
    }

    /// Shutdown barrier, only used off the UI thread after stop().
    func waitUntilStopped() { requests.lock(); requests.unlock() }
}
