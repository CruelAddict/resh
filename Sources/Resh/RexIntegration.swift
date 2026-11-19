import Foundation
import ReshCore

enum RexIntegration {
    /// When resh is invoked through a symlink, return the symlink's path.
    /// Homebrew retargets it on upgrade, so Rex can keep using the same path.
    static func executablePath() throws -> String {
        let command = CommandLine.arguments[0]
        if command.contains("/") { return URL(fileURLWithPath: command).standardizedFileURL.path }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":") {
            let path = URL(fileURLWithPath: directory.isEmpty ? "." : directory).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw ReshError("Cannot locate the resh command. Run it using its full path.")
    }

    static func generateIntegrationLua(executablePath: String) throws -> String {
        guard executablePath.hasPrefix("/"), !executablePath.contains("\0"),
              let resource = Bundle.module.url(forResource: "resh", withExtension: "lua") else {
            throw ReshError("resh print-rex-startup-lua requires an absolute executable path and its Lua resource.")
        }
        let quoted = executablePath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "local executable = \"\(quoted)\"\n\n" + (try String(contentsOf: resource, encoding: .utf8))
    }
}
