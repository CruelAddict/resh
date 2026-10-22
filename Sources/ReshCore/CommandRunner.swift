import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public var text: String { String(decoding: stdout, as: UTF8.self) }

    public init(status: Int32 = 0, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct ReshError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, directory: String?) throws -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> CommandResult {
        try run(executable, arguments, timeout: timeout, directory: nil)
    }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, directory: String?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var environment = ProcessInfo.processInfo.environment
        // The selected Rex target is always explicit; never inherit another pane's context.
        for key in ["TMUX", "REX_SERVER", "REX_CLIENT", "REX_SESSION", "REX_BLOCK", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
            + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // NSTask creates a process group on macOS. Only signal a group when we
        // verified it belongs to this child, never the caller's terminal group.
        let group = getpgid(process.processIdentifier) == process.processIdentifier ? process.processIdentifier : nil
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        for handle in handles {
            let descriptor = handle.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        defer {
            if let group {
                _ = kill(-group, SIGTERM)
                for _ in 0..<20 { if kill(-group, 0) != 0 { break }; usleep(5_000) }
                if kill(-group, 0) == 0 { _ = kill(-group, SIGKILL) }
            } else if process.isRunning {
                process.terminate()
                for _ in 0..<20 { if !process.isRunning { break }; usleep(5_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            for handle in handles { try? handle.close() }
        }
        var data = [Data(), Data()]
        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return CommandResult(status: 124, stdout: data[0],
                    stderr: Data("Command timed out after \(timeout) seconds: \(executable)".utf8))
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let wait = max(0.001, min(0.05, remaining))
            if descriptors.allSatisfy({ $0.fd < 0 }) {
                if exited.wait(timeout: .now() + wait) == .success { break }
                continue
            }
            let ready = Darwin.poll(&descriptors, nfds_t(descriptors.count), Int32(wait * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw ReshError("Could not wait for command output: \(executable)")
            }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = Darwin.read(handles[index].fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    data[index].append(contentsOf: buffer.prefix(count))
                    guard data[0].count + data[1].count <= 2_097_152 else { throw ReshError("Command output exceeded 2 MiB: \(executable)") }
                } else if count == 0 { descriptors[index].fd = -1 }
                else if errno != EAGAIN && errno != EINTR { throw ReshError("Could not read command output: \(executable)") }
            }
            if !process.isRunning && descriptors.allSatisfy({ $0.fd < 0 }) { break }
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: data[0], stderr: data[1])
    }
}

public struct Tools: Sendable {
    public let rex: String
    public let zoxide: String?
    public let fd: String?
    public let git: String
    public let rexApp: String

    public init(rex: String, zoxide: String?, fd: String?, git: String = "/usr/bin/git", rexApp: String) {
        self.rex = rex; self.zoxide = zoxide; self.fd = fd; self.git = git; self.rexApp = rexApp
    }

    public static func discover(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Tools {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func executable(_ paths: [String]) -> String? {
            paths.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        func isDirectory(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
        let app: String
        if let override = environment["RESH_REX_APP"] {
            guard isDirectory(override) else { throw ReshError("RESH_REX_APP is not an application directory: \(override)") }
            app = override
        } else {
            guard let discovered = ["/Applications/Rex Beta.app", "/Applications/Rex.app",
                home + "/Applications/Rex Beta.app", home + "/Applications/Rex.app"].first(where: isDirectory) else {
                throw ReshError("Rex app not found. Set RESH_REX_APP to its application bundle.")
            }
            app = discovered
        }
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let rex: String
        if let override = environment["RESH_REX_BIN"] {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw ReshError("RESH_REX_BIN is not executable: \(override)")
            }
            rex = override
        } else {
            let rexPaths = [environment["REX_BIN_DIR"].map { $0 + "/rex" },
                home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"]
                .compactMap { $0 } + paths.map { $0 + "/rex" }
            guard let discovered = executable(rexPaths) else {
                throw ReshError("Rex CLI not found. Open Rex once, or set RESH_REX_BIN.")
            }
            rex = discovered
        }
        func brewTool(_ name: String) -> String? {
            executable(["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name] + paths.map { $0 + "/" + name })
        }
        return Tools(rex: rex, zoxide: brewTool("zoxide"), fd: brewTool("fd"), rexApp: app)
    }
}
