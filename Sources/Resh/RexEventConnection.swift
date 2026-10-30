import Darwin
import Foundation
import ReshCore

struct RexAppClient: Decodable, Sendable {
    let client: String
    let rexAppPID: Int32
    private enum CodingKeys: String, CodingKey { case client, rexAppPID = "rex_app_pid" }
}

enum RexEventUpdate: Sendable {
    case records([RexAttentionRecord])
    case sessions([RexSession])
    case destroyed(String)
    case clients([RexAppClient])
    case reconnecting
    case hostsChanged
    case capabilitiesChanged
}

/// Supported CLI event streams for the persistent catalog and visible-only activity.
/// All process and pipe state belongs to the serial queue, including teardown.
final class RexEventConnection: @unchecked Sendable {
    enum Kind: String { case catalog, attention }
    private struct Update: Decodable {
        let type: String?
        let sessions: [RexSession]?
        let clients: [RexAppClient]?
        let records: [RexAttentionRecord]?
        let error: String?
        let heartbeat: Bool?
        let sessionID: String?
        private enum CodingKeys: String, CodingKey {
            case type, sessions, clients, records, error, heartbeat
            case sessionID = "session_id"
        }
    }
    private let tools: Tools
    private let kind: Kind
    private let queue = DispatchQueue(label: "resh.events", qos: .utility)
    private let state = NSLock()
    private var requestedGeneration = 0
    private var process: RexProcess?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation = 0
    private var target: RexTarget?
    private var recoveryDeadline: TimeInterval?
    private var retryDelay: TimeInterval = 0.1
    private var onUpdate: (@Sendable (Result<RexEventUpdate, Error>) -> Void)?
    private var childPID: pid_t?
    var processID: pid_t? { state.lock(); defer { state.unlock() }; return childPID }

    init(tools: Tools, kind: Kind = .attention) { self.tools = tools; self.kind = kind }

    deinit {
        output?.readabilityHandler = nil
        try? output?.close()
        process?.stop()
    }

    func start(target: RexTarget, onUpdate: @escaping @Sendable (Result<RexEventUpdate, Error>) -> Void) {
        let request = nextGeneration()
        queue.async { [self] in
            closeConnection()
            guard isCurrent(request) else { return }
            generation = request
            self.onUpdate = onUpdate
            self.target = target
            recoveryDeadline = nil; retryDelay = 0.1
            connect(request: request)
        }
    }

    private func connect(request: Int) {
        guard isCurrent(request), let target else { return }
        let resource = "resh-" + kind.rawValue
        guard let script = Bundle.module.url(forResource: resource, withExtension: "lua") else {
            finish(request: request, error: ReshError("Missing bundled resource: \(resource).lua. Reinstall resh."))
            return
        }
        do {
            let child = try RexProcess(executable: tools.rex,
                arguments: ["--autostart=false", "--server", target.server, "do", script.path, "--all", "--fail-fast"])
            process = child
            state.lock(); childPID = child.pid; state.unlock()
            guard isCurrent(request) else { closeConnection(); return }
            output = child.output
            if let descriptor = output?.fileDescriptor {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            }
            output?.readabilityHandler = { [weak self] _ in
                self?.queue.async { [weak self] in self?.read(request: request) }
            }
        } catch { finish(request: request, error: error) }
    }

    private func recover(request: Int) {
        guard request == generation, isCurrent(request) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if recoveryDeadline == nil {
            recoveryDeadline = now + 5; retryDelay = 0.1
            onUpdate?(.success(.reconnecting))
        }
        closeProcess()
        guard let deadline = recoveryDeadline, now < deadline else {
            finish(request: request, error: ReshError("Can’t reconnect to Rex. Try again."))
            return
        }
        let delay = min(retryDelay, deadline - now)
        retryDelay = min(1, retryDelay * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isCurrent(request) else { return }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                self.finish(request: request, error: ReshError("Can’t reconnect to Rex. Try again."))
            } else { self.connect(request: request) }
        }
    }

    func stop() {
        let request = nextGeneration()
        queue.async { [self] in
            guard isCurrent(request) else { return }
            closeConnection()
        }
    }

    func waitUntilStopped() { queue.sync {} }

    private func nextGeneration() -> Int {
        state.lock(); defer { state.unlock() }
        requestedGeneration += 1
        return requestedGeneration
    }
    private func isCurrent(_ request: Int) -> Bool {
        state.lock(); defer { state.unlock() }; return requestedGeneration == request
    }

    private func read(request: Int) {
        guard request == generation, isCurrent(request), let output else { return }
        // Read only bytes already available, not FileHandle's fill-up-to-count API.
        var bytes = [UInt8](repeating: 0, count: 16384)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR || errno == EAGAIN { return }
        guard count > 0 else { recover(request: request); return }
        buffer.append(contentsOf: bytes.prefix(count))
        guard buffer.count <= 8 * 1024 * 1024 else { finish(request: request, error: ReshError("Rex event update exceeded 8 MiB.")); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            do {
                let update = try JSONDecoder().decode(Update.self, from: line)
                if let error = update.error {
                    if isRexTransportFailure(error) { recover(request: request); return }
                    throw ReshError(error)
                }
                let recovered = recoveryDeadline != nil
                recoveryDeadline = nil; retryDelay = 0.1
                if update.heartbeat == true { continue }
                if isCurrent(request) {
                    if recovered { onUpdate?(.success(.capabilitiesChanged)) }
                    switch update.type {
                    case "sessions": onUpdate?(.success(.sessions(update.sessions ?? [])))
                    case "destroyed":
                        if let id = update.sessionID { onUpdate?(.success(.destroyed(id))) }
                    case "clients": onUpdate?(.success(.clients(update.clients ?? [])))
                    case "hosts": onUpdate?(.success(.hostsChanged))
                    case "capabilities": onUpdate?(.success(.capabilitiesChanged))
                    case nil: onUpdate?(.success(.records(update.records ?? [])))
                    default: break
                    }
                }
            } catch {
                finish(request: request, error: error); return
            }
        }
    }

    private func finish(request: Int, error: Error) {
        guard request == generation, isCurrent(request) else { return }
        let callback = onUpdate
        onUpdate = nil
        closeConnection()
        callback?(.failure(error))
    }

    private func closeConnection() {
        onUpdate = nil
        target = nil; recoveryDeadline = nil
        closeProcess()
    }

    private func closeProcess() {
        output?.readabilityHandler = nil
        process?.stop()
        process = nil; output = nil; buffer = Data()
        state.lock(); childPID = nil; state.unlock()
    }
}
