import Foundation

public actor ReshService {
    private let client: RexClient
    private let registry: SessionRegistry
    private let history: SessionHistory
    public init(client: RexClient, registry: SessionRegistry = SessionRegistry()) {
        self.client = client; self.registry = registry
        self.history = SessionHistory()
    }

    private init(client: RexClient, registry: SessionRegistry, history: SessionHistory) {
        self.client = client; self.registry = registry; self.history = history
    }

    public nonisolated func at(_ target: RexTarget) -> ReshService {
        ReshService(client: RexClient(tools: client.tools, target: target, runner: client.runner), registry: registry, history: history)
    }

    public nonisolated var target: RexTarget { client.target }
    public nonisolated func hosts() throws -> (hosts: [RexHost], warnings: [String]) { try RexHostCatalog(client: client).read() }
    public nonisolated func remote(_ host: RexHost) -> RexRemote { RexRemote(client: client.at(host)) }
    public nonisolated func sessions(host: RexHost? = nil) throws -> [RexSession] { try (host.map(client.at) ?? client).sessions() }

    public nonisolated static func candidates(from sessions: [RexSession], host: RexHost? = nil) -> [Candidate] {
        // A Rex session has no global working directory. Do not inspect its tabs.
        sessions.map { Candidate(id: Candidate.identity($0.sessionID, host: host), kind: .session, title: $0.label, sessionID: $0.sessionID, host: host) }
    }

    public func resolveClient() throws -> (id: String, rexAppPID: Int32?) { try client.resolveClient() }

    public func recentSessionIDs() throws -> [String] {
        let clientID = try client.target.clientID ?? client.resolveClient().id
        return history.withVisits { visits in
            visits.filter { $0.belongs(to: clientID, server: client.target.server) }.map(\.candidateID)
        }
    }

    public nonisolated func recentSessionIDsByClient() -> [String: [String]] {
        history.withVisits { visits in
            var result: [String: [String]] = [:]
            for visit in visits where visit.server == client.target.server {
                result[visit.clientID, default: []].append(visit.candidateID)
            }
            return result
        }
    }

    public func recordVisit(sessionID: String, host: RexHost? = nil, clientID: String) {
        history.withVisits { visits in
            SessionHistory.record(sessionID, host: host, clientID: clientID, server: client.target.server, visits: &visits)
        }
    }

    public func forgetSession(sessionID: String, host: RexHost? = nil) {
        let candidateID = Candidate.identity(sessionID, host: host)
        history.withVisits { visits in
            visits.removeAll { $0.server == client.target.server && $0.candidateID == candidateID }
        }
    }

    public func connect(_ path: String, configuration: ReshConfiguration, cwd: String) throws -> (sessionID: String, path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path
        let directory = PathIdentity.canonical(absolute)
        let project = configuration.projects.first { $0.name == path } ?? configuration.project(at: directory)
        let candidate = project?.candidate ?? Candidate(id: directory, kind: .directory,
            title: directory, path: directory, startupCommand: configuration.defaultStartupCommand)
        let sessionID = try connect(candidate)
        return (sessionID, project?.path ?? directory)
    }

    /// Paths are sent as JSON arguments, never interpolated into a shell command.
    @discardableResult
    public func connect(_ candidate: Candidate) throws -> String {
        try history.withVisits { visits in
            let targetClient = try client.resolveClient().id
            let sessionID = try open(candidate, clientID: targetClient)
            SessionHistory.record(sessionID, host: candidate.host, clientID: targetClient, server: client.target.server, visits: &visits)
            return sessionID
        }
    }

    private func open(_ candidate: Candidate, clientID targetClient: String) throws -> String {
        if let sessionID = candidate.sessionID {
            try client.select(sessionID, clientID: targetClient)
            return sessionID
        }
        guard let rawPath = candidate.path else { throw ReshError("The selected folder has no path.") }
        if let host = candidate.host {
            let remote = client.at(host)
            let directory = try RexRemote(client: remote).directory(rawPath)
            return try create(path: directory.path, clientID: targetClient, name: directory.name,
                              startupCommand: nil, dataClient: remote, registryKey: host.id)
        }
        let path = PathIdentity.canonical(rawPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReshError("This folder no longer exists: \(path)")
        }
        let id = try create(path: path, clientID: targetClient,
            name: candidate.kind == .project ? candidate.title : SessionNamer(runner: client.runner, git: client.tools.git).name(for: path),
            startupCommand: candidate.startupCommand, dataClient: client, registryKey: client.target.server)
        if let zoxide = client.tools.zoxide { _ = try? client.runner.run(zoxide, ["add", path], timeout: 3) }
        return id
    }

    /// The first entry is the last selection made by resh, not inferred app focus.
    @discardableResult
    public func connectLast() throws -> String? {
        try history.withVisits { visits in
            let clientID = try client.resolveClient().id
            let previous = visits.filter { $0.belongs(to: clientID, server: client.target.server) }.dropFirst()
            var catalog: [RexHost]?, snapshots: [String: [RexSession]] = [:]
            for visit in previous {
                let host: RexHost?
                if let saved = visit.host {
                    if catalog == nil { catalog = try hosts().hosts }
                    host = catalog?.first { $0.id == saved.id }
                    if host == nil {
                        visits.removeAll { $0.belongs(to: clientID, server: client.target.server) && $0.candidateID == visit.candidateID }
                        continue
                    }
                } else { host = nil }
                let key = host?.id ?? client.target.server
                if snapshots[key] == nil { snapshots[key] = try sessions(host: host) }
                guard let session = snapshots[key]?.first(where: { $0.sessionID == visit.sessionID }) else {
                    visits.removeAll { $0.belongs(to: clientID, server: client.target.server) && $0.candidateID == visit.candidateID }
                    continue
                }
                let candidate = Candidate(id: visit.candidateID, kind: .session, title: session.label,
                    sessionID: session.sessionID, host: host)
                let id = try open(candidate, clientID: clientID)
                SessionHistory.record(id, host: host, clientID: clientID, server: client.target.server, visits: &visits)
                return id
            }
            return nil
        }
    }

    private func create(path: String, clientID: String, name: String, startupCommand: String?,
                        dataClient: RexClient, registryKey: String) throws -> String {
        let lock = try FileLock(url: registry.directory.appendingPathComponent("create.lock"))
        defer { withExtendedLifetime(lock) {} }
        let sessions = try dataClient.sessions()
        let liveIDs = Set(sessions.map(\.sessionID))
        var records = try registry.load().filter { $0.server != registryKey || liveIDs.contains($0.sessionID) }
        if let record = records.first(where: { $0.server == registryKey && $0.path == path }) {
            try client.select(record.sessionID, clientID: clientID)
            return record.sessionID
        }
        // An unregistered session's current tab directory is not its identity.
        // Only resh's explicit creation records can associate a folder with a session.
        let label = SessionNamer.availableName(base: name, path: path, occupied: Set(sessions.map(\.label)))
        var options: [String: Any] = ["cwd": path]
        if let startupCommand, !startupCommand.isEmpty {
            let quotedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            options["initial_input"] = startupCommand.replacingOccurrences(of: "{}", with: quotedPath) + "\n"
        }
        let reply = try dataClient.api("session.create", ["label": label, "initial_windows": [[
            "window_label": "Terminal",
            "layout": ["block": ["flavor": "com.superlogical.terminal.shell", "options": options]],
        ]]])
        struct Created: Decodable { let session_id: String }
        let sessionID = try JSONDecoder().decode(Created.self, from: reply).session_id
        // Save before selecting: if Remote Control is disabled, retrying must not duplicate a session.
        records.append(SessionRecord(server: registryKey, path: path, sessionID: sessionID))
        try registry.save(records)
        do { try client.select(sessionID, clientID: clientID) }
        catch {
            throw ReshError("Created ‘\(label)’, but could not switch Rex to it. Retrying will reuse it.\n\(error.localizedDescription)",
                userMessage: (error as? ReshError)?.userMessage)
        }
        return sessionID
    }

    /// A successful return confirms absence. Registry cleanup is optional.
    public func delete(sessionID: String, host: RexHost? = nil) throws {
        let dataClient = host.map(client.at) ?? client
        let registryKey = host?.id ?? client.target.server
        do {
            _ = try dataClient.command(["kill", sessionID])
        } catch {
            let deletionError = error
            let sessions: [RexSession]
            do { sessions = try dataClient.sessions() }
            catch {
                throw ReshError("Could not confirm whether the session was closed.\n\(deletionError.localizedDescription)\n\(error.localizedDescription)")
            }
            if sessions.contains(where: { $0.sessionID == sessionID }) { throw deletionError }
        }
        forgetSession(sessionID: sessionID, host: host)
        do {
            let lock = try FileLock(url: registry.directory.appendingPathComponent("create.lock"), wait: false)
            defer { withExtendedLifetime(lock) {} }
            let records = try registry.load()
            try registry.save(records.filter { $0.server != registryKey || $0.sessionID != sessionID })
        } catch {
            DebugLog.shared.record(error, source: "registry:cleanup")
        }
    }
}
