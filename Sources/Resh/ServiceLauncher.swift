import Darwin
import Foundation
import ReshCore

enum ServiceStartMode { case ifStopped, requireCurrentVersion, restart }

/// Rex Server starts the host so file access belongs to Rex Server's app identity.
/// The plist retains launch preferences; it is no longer registered with launchd.
struct ServiceLauncher {
    static let version = Bundle.main.object(forInfoDictionaryKey: "ReshVersion") as? String ?? "development"

    private let directory: URL
    private let label = "io.github.CruelAddict.resh.panel"
    private let runner: any CommandRunning
    private let send: (LauncherRequest) throws -> [String: Any]?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/resh"),
         runner: any CommandRunning = SystemCommandRunner(),
         send: @escaping (LauncherRequest) throws -> [String: Any]? = { try LauncherIPC.send($0) }) {
        self.directory = directory; self.runner = runner; self.send = send
    }

    var plistURL: URL { directory.appendingPathComponent("launcher.plist") }
    private var job: String { "gui/\(getuid())/\(label)" }

    private func definition(executable: String, configurationPath: String?, environment: [String: String], debug: Bool) -> [String: Any] {
        var arguments = [executable, "serve"]
        if let configurationPath { arguments += ["--config", configurationPath] }
        if debug { arguments.append("--debug") }
        // Do not persist arbitrary shell credentials or another pane's Rex IDs.
        let keys: Set<String> = ["PATH", "XDG_CONFIG_HOME", "RESH_REX_BIN", "RESH_REX_APP", "RESH_CONFIG"]
        return ["ProgramArguments": arguments,
            "EnvironmentVariables": environment.filter { keys.contains($0.key) }]
    }

    func start(_ mode: ServiceStartMode, executable: String, configurationPath: String?,
               environment: [String: String] = ProcessInfo.processInfo.environment, debug: Bool = false) throws {
        let lock = try FileLock(url: directory.appendingPathComponent("launcher.lock"))
        defer { withExtendedLifetime(lock) {} }
        let status = try send(LauncherRequest(operation: "status"))
        if let status, status["stopping"] as? Bool != true {
            if mode == .ifStopped { return }
            if mode == .requireCurrentVersion, status["version"] as? String == Self.version { return }
        }

        var settings = try savedDefinition() ?? definition(executable: executable,
            configurationPath: configurationPath, environment: environment, debug: debug)
        var arguments = settings["ProgramArguments"] as? [String] ?? [executable, "serve"]
        arguments[0] = executable
        if let configurationPath {
            if let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) {
                arguments[index + 1] = configurationPath
            } else { arguments += ["--config", configurationPath] }
        }
        if debug, !arguments.contains("--debug") { arguments.append("--debug") }
        settings = ["ProgramArguments": arguments,
            "EnvironmentVariables": settings["EnvironmentVariables"] ?? [:]]
        let savedEnvironment = settings["EnvironmentVariables"] as? [String: String] ?? [:]
        let tools = try Tools.discover(environment: environment.merging(savedEnvironment) { _, saved in saved })

        if mode != .ifStopped {
            try rex(tools: tools, environment: savedEnvironment, arguments: ["config", "reload"])
        }
        try stopHost()
        let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
        try rex(tools: tools, environment: savedEnvironment, arguments: ["do", "resh_serve"])
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            if let response = try send(LauncherRequest(operation: "status")) {
                guard mode == .ifStopped || response["version"] as? String == Self.version else {
                    throw ReshError("Rex started a different resh version. Run resh setup to reconnect the installed version.")
                }
                return
            }
            usleep(10_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw ReshError("The resh service did not start through Rex Server.")
    }

    func stop() throws {
        let lock = try FileLock(url: directory.appendingPathComponent("launcher.lock"))
        defer { withExtendedLifetime(lock) {} }
        try stopHost()
    }

    private func stopHost() throws {
        _ = try send(LauncherRequest(operation: "quit"))
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while try send(LauncherRequest(operation: "status")) != nil {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ReshError("The resh service did not stop.")
            }
            usleep(20_000)
        }
        // Retire the previous launchd host when upgrading an existing installation.
        if try command(["print", job]).status == 0 {
            let result = try command(["bootout", job])
            guard result.status == 0 else {
                throw ReshError("Cannot remove resh's old launchd job.\n" + String(decoding: result.stderr, as: UTF8.self))
            }
        }
    }

    func savedServeArguments() throws -> [String] {
        let settings = try savedDefinition()
        for (key, value) in settings?["EnvironmentVariables"] as? [String: String] ?? [:] {
            setenv(key, value, 1)
        }
        return ["serve"] + (settings?["ProgramArguments"] as? [String] ?? []).dropFirst(2)
    }

    private func savedDefinition() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return nil }
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
    }

    private func rex(tools: Tools, environment: [String: String], arguments: [String]) throws {
        let result = try runner.run("/usr/bin/env",
            environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                + [tools.rex, "--autostart=false", "--timeout", "15s"] + arguments, timeout: 20)
        guard result.status == 0 else {
            throw ReshError("Cannot launch resh through Rex Server: " + String(decoding: result.stderr, as: UTF8.self))
        }
    }

    private func command(_ arguments: [String]) throws -> CommandResult {
        try runner.run("/bin/launchctl", arguments, timeout: 5)
    }
}
