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
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func set(_ data: Data) { lock.lock(); defer { lock.unlock() }; storage = data }
    var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
        try process.run()

        let group = DispatchGroup(), stdout = DataBox(), stderr = DataBox()
        for (pipe, box) in [(output, stdout), (errors, stderr)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.set(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        group.wait()
        return CommandResult(status: process.terminationStatus, stdout: stdout.value, stderr: stderr.value)
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
        let app = [environment["RESH_REX_APP"], "/Applications/Rex Beta.app", "/Applications/Rex.app",
                   home + "/Applications/Rex Beta.app", home + "/Applications/Rex.app"]
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) } ?? "/Applications/Rex Beta.app"
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let rexPaths = [environment["RESH_REX_BIN"], environment["REX_BIN_DIR"].map { $0 + "/rex" },
            home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"]
            .compactMap { $0 } + paths.map { $0 + "/rex" }
        guard let rex = executable(rexPaths) else {
            throw ReshError("Rex CLI not found. Open Rex once, or set RESH_REX_BIN.")
        }
        func brewTool(_ name: String) -> String? {
            executable(["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name] + paths.map { $0 + "/" + name })
        }
        return Tools(rex: rex, zoxide: brewTool("zoxide"), fd: brewTool("fd"), rexApp: app)
    }
}
