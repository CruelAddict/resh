import Darwin
import Foundation
import ReshCore

/// A separate supported CLI event stream never delays the session-list fast path.
/// All process and pipe state belongs to the serial queue, including teardown.
final class RexAttentionConnection: @unchecked Sendable {
    private struct Update: Decodable { let records: [RexAttentionRecord]?; let error: String?; let heartbeat: Bool? }
    private let tools: Tools
    private let queue = DispatchQueue(label: "resh.attention", qos: .utility)
    private let state = NSLock()
    private var requestedGeneration = 0
    private var process: RexProcess?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation = 0
    private var target: RexTarget?
    private var recoveryDeadline: TimeInterval?
    private var retryDelay: TimeInterval = 0.1
    private var onUpdate: (@Sendable (Result<[RexAttentionRecord], Error>) -> Void)?

    init(tools: Tools) { self.tools = tools }

    deinit {
        output?.readabilityHandler = nil
        try? output?.close()
        process?.stop()
    }

    func start(target: RexTarget, onUpdate: @escaping @Sendable (Result<[RexAttentionRecord], Error>) -> Void) {
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
        guard let script = Bundle.module.url(forResource: "resh-attention", withExtension: "lua") else {
            finish(request: request, error: ReshError("Missing bundled resource: resh-attention.lua. Reinstall resh."))
            return
        }
        do {
            let child = try RexProcess(executable: tools.rex,
                arguments: ["--autostart=false", "--server", target.server, "do", script.path, "--all", "--fail-fast"])
            process = child
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
        }
        closeProcess()
        guard let deadline = recoveryDeadline, now < deadline else {
            finish(request: request, error: ReshError("Can’t reconnect to Rex activity. Try again."))
            return
        }
        let delay = min(retryDelay, deadline - now)
        retryDelay = min(1, retryDelay * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isCurrent(request) else { return }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                self.finish(request: request, error: ReshError("Can’t reconnect to Rex activity. Try again."))
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
        guard buffer.count <= 2 * 1024 * 1024 else { finish(request: request, error: ReshError("Rex activity update exceeded 2 MiB.")); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            do {
                let update = try JSONDecoder().decode(Update.self, from: line)
                if let error = update.error {
                    if isRexTransportFailure(error) { recover(request: request); return }
                    throw ReshError(error)
                }
                recoveryDeadline = nil; retryDelay = 0.1
                if update.heartbeat == true { continue }
                if isCurrent(request) { onUpdate?(.success(update.records ?? [])) }
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
    }
}
