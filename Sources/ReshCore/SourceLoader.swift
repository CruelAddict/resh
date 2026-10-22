import Foundation

public struct SourceResult: Sendable {
    public var entries: [Candidate] = []
    public var warnings: [String] = []
}

/// Providers run off the main actor. Their output is data, never shell input.
public struct SourceLoader: Sendable {
    public let tools: Tools
    public let runner: any CommandRunning
    public init(tools: Tools, runner: any CommandRunning = SystemCommandRunner()) {
        self.tools = tools; self.runner = runner
    }
    /// Already available rows can be displayed while filesystem providers run.
    public func availableEntries(_ id: SearchScope, configuration: ReshConfiguration, sessions: [Candidate]) -> [Candidate] {
        guard let source = configuration.source(id) else { return [] }
        switch source.kind {
        case .sessions: return sessions
        case .projects: return configuration.projects.map(\.candidate)
        case .union:
            var seen = Set<String>()
            return source.members.flatMap { availableEntries($0, configuration: configuration, sessions: sessions) }
                .filter { seen.insert($0.path.map { "path:" + $0 } ?? $0.id).inserted }
        default: return []
        }
    }
    public func load(_ id: SearchScope, configuration: ReshConfiguration, sessions: [Candidate]) throws -> SourceResult {
        try Task.checkCancellation()
        guard let source = configuration.source(id) else { throw ReshError("Unknown source: \(id.rawValue)") }
        switch source.kind {
        case .sessions: return SourceResult(entries: sessions)
        case .projects: return SourceResult(entries: configuration.projects.map(\.candidate))
        case .union:
            var result = SourceResult(), seen = Set<String>()
            for member in source.members {
                let part = try load(member, configuration: configuration, sessions: sessions)
                result.warnings += part.warnings
                result.entries += part.entries.filter { seen.insert($0.path.map { "path:" + $0 } ?? $0.id).inserted }
            }
            return result
        case .paths: return SourceResult(entries: try candidates(source.paths, configuration: configuration))
        case .zoxide:
            guard let zoxide = tools.zoxide else { return SourceResult(warnings: ["zoxide not found. Choose a folder-search source, or install zoxide."]) }
            let result = try runner.run(zoxide, ["query", "-l"], timeout: source.timeout, directory: source.cwd)
            guard result.status == 0 else { return SourceResult(warnings: [commandError(result, source: source).message]) }
            return SourceResult(entries: try candidates(result.text.split(separator: "\n").prefix(20_000).map(String.init), configuration: configuration))
        case .find:
            guard let fd = tools.fd else { throw ReshError("Find folders needs fd. Install it with brew install fd.") }
            let result = try runner.run(fd, ["-H", "-d", "2", "-t", "d", "-E", ".Trash", "--print0", ".",
                FileManager.default.homeDirectoryForCurrentUser.path], timeout: source.timeout, directory: nil)
            let paths = result.text.split(separator: "\0").prefix(20_000).map(String.init)
            return SourceResult(entries: try candidates(paths, configuration: configuration),
                warnings: result.status == 0 ? [] : [commandError(result, source: source).message])
        case .command:
            let executable = try resolve(source.command[0], cwd: source.cwd)
            return try command(executable, Array(source.command.dropFirst()), source: source, configuration: configuration)
        }
    }
    private func command(_ executable: String, _ arguments: [String], source: SourceDefinition,
                         configuration: ReshConfiguration) throws -> SourceResult {
        let result = try runner.run(executable, arguments, timeout: source.timeout, directory: source.cwd)
        guard result.status == 0 else { throw commandError(result, source: source) }
        guard let text = String(data: result.stdout, encoding: .utf8), !text.contains("\0") else {
            throw ReshError("\(source.title) must return UTF-8 paths, one per line.")
        }
        let lines = text.split(separator: "\n").map { line -> String in
            let path = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            let expanded = (path as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: source.cwd).appendingPathComponent(expanded).path
        }
        guard lines.count <= 20_000 else { throw ReshError("\(source.title) returned more than 20,000 paths.") }
        return SourceResult(entries: try candidates(lines, configuration: configuration))
    }
    private func commandError(_ result: CommandResult, source: SourceDefinition) -> ReshError {
        let message = String(decoding: result.stderr.prefix(1000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ReshError("\(source.title) exited with status \(result.status). \(message)")
    }

    private func candidates(_ paths: [String], configuration: ReshConfiguration) throws -> [Candidate] {
        let projects = Dictionary(uniqueKeysWithValues: configuration.projects.map { ($0.path, $0.candidate) })
        return try PathIdentity.directories(paths).map {
            projects[$0.path ?? ""] ?? Candidate(id: $0.id, kind: .directory, title: $0.title, path: $0.path,
                                               startupCommand: configuration.defaultStartupCommand)
        }
    }
    private func resolve(_ name: String, cwd: String) throws -> String {
        let expanded = (name as NSString).expandingTildeInPath
        let paths: [String]
        if expanded.contains("/") { paths = [expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path] }
        else {
            let search = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            paths = search.split(separator: ":").map { String($0) + "/" + name }
        }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ReshError("Source executable not found: \(name)")
        }
        return path
    }
}
