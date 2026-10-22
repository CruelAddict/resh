import Darwin
import Foundation
import ReshCore

/// A separate supported CLI event stream never delays the session-list fast path.
/// All process and pipe state belongs to the serial queue, including teardown.
final class RexAttentionConnection: @unchecked Sendable {
    private struct Update: Decodable { let records: [RexAttentionRecord]? }
    private let tools: Tools
    private let queue = DispatchQueue(label: "resh.attention", qos: .utility)
    private var process: Process?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation = 0
    private var onUpdate: (@Sendable ([RexAttentionRecord]) -> Void)?

    init(tools: Tools) { self.tools = tools }

    deinit {
        output?.readabilityHandler = nil
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
    }

    func start(target: RexTarget, onUpdate: @escaping @Sendable ([RexAttentionRecord]) -> Void) {
        queue.async { [self] in
            closeConnection()
            self.onUpdate = onUpdate
            let request = generation
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("resh-attention.lua")
            let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("integration/resh-attention.lua")
            let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development
            let child = Process(), stdout = Pipe()
            child.executableURL = URL(fileURLWithPath: tools.rex)
            child.arguments = ["--autostart=false", "--server", target.server, "do", script.path, "--all", "--fail-fast"]
            var environment = ProcessInfo.processInfo.environment
            for key in ["REX_SESSION", "REX_BLOCK", "REX_CLIENT", "REX_SERVER"] { environment.removeValue(forKey: key) }
            child.environment = environment
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = stdout
            child.standardError = FileHandle.nullDevice
            do {
                try child.run()
                process = child
                output = stdout.fileHandleForReading
                if let descriptor = output?.fileDescriptor {
                    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                }
                output?.readabilityHandler = { [weak self] _ in
                    self?.queue.async { [weak self] in self?.read(request: request) }
                }
            } catch { finish(request: request) }
        }
    }

    func stop() {
        queue.sync {
            onUpdate = nil
            closeConnection()
        }
    }

    private func read(request: Int) {
        guard request == generation, let output else { return }
        // Read only bytes already available, not FileHandle's fill-up-to-count API.
        var bytes = [UInt8](repeating: 0, count: 16384)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR || errno == EAGAIN { return }
        guard count > 0 else { finish(request: request); return }
        buffer.append(contentsOf: bytes.prefix(count))
        guard buffer.count <= 2 * 1024 * 1024 else { finish(request: request); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let update = try? JSONDecoder().decode(Update.self, from: line) else {
                finish(request: request)
                return
            }
            onUpdate?(update.records ?? [])
        }
    }

    private func finish(request: Int) {
        guard request == generation else { return }
        let callback = onUpdate
        onUpdate = nil
        closeConnection()
        callback?([]) // Never leave stale dots behind after a disconnected stream.
    }

    private func closeConnection() {
        generation += 1
        output?.readabilityHandler = nil
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; output = nil; buffer = Data()
    }
}
