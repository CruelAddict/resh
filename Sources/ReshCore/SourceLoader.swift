import Foundation

public struct SourceResult: Sendable {
    public var warnings: [String] = []
    public var entriesBySource: [SearchScope: [Candidate]] = [:]
}

/// Providers run off the main actor. Their output is data, never shell input.
public struct SourceLoader: Sendable {
    public let tools: Tools
    public let runner: any CommandRunning
    public init(tools: Tools, runner: any CommandRunning = SystemCommandRunner()) {
        self.tools = tools; self.runner = runner
    }
    /// Already available rows can be displayed while filesystem providers run.
    public func availableEntries(_ id: SearchScope, configuration: ReshConfiguration, sessions: [Candidate],
                                 entriesBySource: [SearchScope: [Candidate]] = [:], remoteEntriesBySource: [[SearchScope: [Candidate]]] = [],
                                 agents: [Candidate] = []) -> [Candidate] {
        guard let source = configuration.source(id) else { return [] }
        func entries(_ source: SourceDefinition) -> [Candidate] {
            switch source.kind {
            case .sessions: return sessions
            case .agents: return agents
            case .projects: return configuration.projects.map(\.candidate)
            default:
                var rows = entriesBySource[source.id] ?? []
                for remote in remoteEntriesBySource {
                    if let extra = remote[source.id] { rows += extra }
                }
                return rows
            }
        }
        guard source.kind == .union else { return entries(source) }
        return unionEntries(configuration.flattenedSources(source).flatMap(entries))
    }
    public func loadSources(_ id: SearchScope, configuration: ReshConfiguration) throws -> SourceResult {
        guard let source = configuration.source(id) else { throw ReshError("Unknown source: \(id.rawValue)") }
        var result = SourceResult()
        for leaf in configuration.flattenedSources(source) {
            try Task.checkCancellation()
            try load(leaf, configuration: configuration, into: &result)
        }
        return result
    }
    private func load(_ source: SourceDefinition, configuration: ReshConfiguration, into result: inout SourceResult) throws {
        switch source.kind {
        case .sessions, .agents, .projects, .union: break
        case .paths: result.entriesBySource[source.id] = try candidates(source.paths, configuration: configuration)
        case .zoxide:
            guard let zoxide = tools.zoxide else { return }
            let output = try runner.run(zoxide, ["query", "-l"], timeout: source.timeout, directory: source.cwd)
            guard output.status == 0 else { result.warnings.append(commandError(output, source: source).message); return }
            result.entriesBySource[source.id] = try candidates(output.text.split(separator: "\n").prefix(20_000).map(String.init), configuration: configuration)
        case .find:
            guard let fd = tools.fd else { return }
            let output = try runner.run(fd, ["-H", "-d", "2", "-t", "d", "-E", ".Trash", "--print0", ".",
                FileManager.default.homeDirectoryForCurrentUser.path], timeout: source.timeout, directory: nil)
            let paths = output.text.split(separator: "\0").prefix(20_000).map(String.init)
            result.entriesBySource[source.id] = try candidates(paths, configuration: configuration)
            if output.status != 0 { result.warnings.append(commandError(output, source: source).message) }
        case .command:
            let executable = try resolve(source.command[0], cwd: source.cwd)
            result.entriesBySource[source.id] = try command(executable, Array(source.command.dropFirst()), source: source, configuration: configuration)
        }
    }
    private func unionEntries(_ entries: [Candidate]) -> [Candidate] {
        var sessionNames: [String?: Set<String>] = [:], seen = Set<String>()
        for entry in entries where entry.kind == .session {
            sessionNames[entry.host?.id, default: []].insert(entry.title)
        }
        return entries.filter {
            if $0.kind == .project, sessionNames[$0.host?.id]?.contains($0.title) == true { return false }
            return seen.insert($0.deduplicationID).inserted
        }
    }
    private func command(_ executable: String, _ arguments: [String], source: SourceDefinition,
                         configuration: ReshConfiguration) throws -> [Candidate] {
        let result = try runner.run(executable, arguments, timeout: source.timeout, directory: source.cwd)
        guard result.status == 0 else { throw commandError(result, source: source) }
        guard let text = String(data: result.stdout, encoding: .utf8), !text.contains("\0") else {
            throw ReshError("\(source.name) must return UTF-8 paths, one per line.")
        }
        let lines = text.split(separator: "\n").map { line -> String in
            let path = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            let expanded = (path as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: source.cwd).appendingPathComponent(expanded).path
        }
        guard lines.count <= 20_000 else { throw ReshError("\(source.name) returned more than 20,000 paths.") }
        return try candidates(lines, configuration: configuration)
    }
    private func commandError(_ result: CommandResult, source: SourceDefinition) -> ReshError {
        let message = String(decoding: result.stderr.prefix(1000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ReshError("\(source.name) exited with status \(result.status). \(message)")
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
