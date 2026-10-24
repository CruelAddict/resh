import CoreFoundation
import Darwin
import Foundation
import ReshCore

/// A per-GUI-session launchd job, not an always-installed login item. There is
/// no extra watchdog process: launchd starts the actual AppKit host directly.
struct ResidentLauncher {
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/resh")
    private let label = "io.github.CruelAddict.resh.panel"

    var plistURL: URL { directory.appendingPathComponent("launcher.plist") }
    var domain: String { "gui/\(getuid())" }
    var job: String { "\(domain)/\(label)" }

    func definition(executable: String, configurationPath: String?, environment: [String: String], debug: Bool = false) -> [String: Any] {
        var arguments = [executable, "--standby"]
        if let configurationPath { arguments += ["--config", configurationPath] }
        if debug { arguments.append("--debug") }
        // Do not persist arbitrary shell credentials or another pane's Rex IDs.
        let keys: Set<String> = ["PATH", "XDG_CONFIG_HOME", "RESH_REX_BIN", "RESH_REX_APP", "RESH_CONFIG"]
        return ["Label": label, "ProgramArguments": arguments,
            "EnvironmentVariables": environment.filter { keys.contains($0.key) },
            "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 2, "ExitTimeOut": 1,
            "ProcessType": "Interactive", "AbandonProcessGroup": false,
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
    }

    func start(executable: String, configurationPath: String?,
               environment: [String: String] = ProcessInfo.processInfo.environment,
               restart: Bool = false, debug: Bool = false) throws {
        let lock = try FileLock(url: directory.appendingPathComponent("launcher.lock"))
        defer { withExtendedLifetime(lock) {} }
        if restart { try stopHost() }
        if CFMessagePortCreateRemote(nil, LauncherIPC.name) != nil { return }
        let loaded = try command(["print", job]).status == 0
        // Only --start replaces this login session's startup arguments.
        if !loaded {
            let definition = definition(executable: executable, configurationPath: configurationPath, environment: environment, debug: debug)
            let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
            try requireSuccess(command(["bootstrap", domain, plistURL.path]))
        }
        // Without -k: never kill a host which is still starting. A successful
        // explicit Quit stays stopped until another show/start requests it.
        try requireSuccess(command(["kickstart", job]))
    }

    func stop() throws {
        let lock = try FileLock(url: directory.appendingPathComponent("launcher.lock"))
        defer { withExtendedLifetime(lock) {} }
        try stopHost(unload: false)
    }

    private func stopHost(unload: Bool = true) throws {
        let response = try LauncherIPC.send(LauncherRequest(operation: "quit"))
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while CFMessagePortCreateRemote(nil, LauncherIPC.name) != nil {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ReshError("The resh helper did not stop.")
            }
            usleep(20_000)
        }
        if unload || response == nil {
            if try command(["print", job]).status == 0 { try requireSuccess(command(["bootout", job])) }
        }
    }

    private func command(_ arguments: [String]) throws -> CommandResult {
        try SystemCommandRunner().run("/bin/launchctl", arguments, timeout: 5)
    }
    private func requireSuccess(_ result: CommandResult) throws {
        guard result.status == 0 else {
            throw ReshError("Cannot start resh's launchd job.\n" + String(decoding: result.stderr, as: UTF8.self))
        }
    }
}
