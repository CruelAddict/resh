import Foundation
import Darwin
import ReshCore

struct RexSnapshot: Decodable {
    let client: String
    let sessions: [RexSession]?
}

/// Keep one supported `rex do` connection open, rather than starting CLI programs
/// on every hotkey. The Lua side reads server state anew for every request.
final class RexDataConnection: @unchecked Sendable {
    private let tools: Tools
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    init(tools: Tools, timeout: TimeInterval = 5) { self.tools = tools; self.timeout = timeout }

    func warmup() throws {
        lock.lock(); defer { lock.unlock() }
        try startIfNeeded()
    }

    func snapshot(appPID: Int32) throws -> RexSnapshot {
        lock.lock(); defer { lock.unlock() }
        try startIfNeeded()
        do {
            var request = try JSONSerialization.data(withJSONObject: ["pid": appPID])
            request.append(10)
            try input?.write(contentsOf: request)
            let response = try readLine()
            if let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
               let error = object["error"] as? String { throw ReshError(error) }
            return try JSONDecoder().decode(RexSnapshot.self, from: response)
        } catch {
            closeConnection()
            throw error
        }
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        closeConnection()
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("resh-data.lua")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("integration/resh-data.lua")
        let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: tools.rex)
        child.arguments = ["--autostart=false", "--server", RexTarget().server, "do", script.path]
        var environment = ProcessInfo.processInfo.environment
        for key in ["REX_SESSION", "REX_BLOCK", "REX_CLIENT", "REX_SERVER"] { environment.removeValue(forKey: key) }
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        try child.run()
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        do {
            let hello = try JSONSerialization.jsonObject(with: readLine()) as? [String: Any]
            guard hello?["ready"] as? Bool == true else { throw ReshError("Invalid Rex data connection handshake.") }
        } catch { closeConnection(); throw error }
    }

    private func readLine() throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard let output else { throw ReshError("The Rex data connection is not open.") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ReshError("The Rex data connection timed out.") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw ReshError("The Rex data connection timed out.") }
            // FileHandle.read(upToCount:) tries to fill the requested length on a pipe.
            // A POSIX read returns the available response immediately, without waiting for EOF.
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw ReshError("The Rex data connection closed. Try opening resh again.")
            }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 8 * 1024 * 1024 else { throw ReshError("The Rex snapshot is too large.") }
        }
    }

    private func closeConnection() {
        try? input?.close(); try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil; buffer = Data()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        closeConnection()
    }
}
