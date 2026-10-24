import Foundation

public actor ReshService {
    private let client: RexClient
    private let registry: SessionRegistry
    private let history: SessionHistory
    public init(client: RexClient, registry: SessionRegistry = SessionRegistry()) {
        self.client = client; self.registry = registry
        self.history = SessionHistory(directory: registry.directory)
    }

    public nonisolated var target: RexTarget { client.target }
    public nonisolated func hosts() throws -> (hosts: [RexHost], warnings: [String]) { try RexHostCatalog(client: client).read() }
    public nonisolated func remote(_ host: RexHost) -> RexRemote { RexRemote(client: client.at(host)) }

    public nonisolated static func candidates(from sessions: [RexSession], host: RexHost? = nil) -> [Candidate] {
        // A Rex session has no global working directory. Do not inspect its tabs.
        sessions.map { Candidate(id: Candidate.identity($0.sessionID, host: host), kind: .session, title: $0.label, sessionID: $0.sessionID, host: host) }
    }

    public func resolveClient() throws -> (id: String, rexAppPID: Int32?) { try client.resolveClient() }

    public func recentSessionIDs() throws -> [String] {
        let clientID = try client.target.clientID ?? client.resolveClient().id
        return try history.load().filter { $0.belongs(to: clientID, server: client.target.server) }.map(\.candidateID)
    }

    /// Paths are sent as JSON arguments, never interpolated into a shell command.
    @discardableResult
    public func connect(_ candidate: Candidate) throws -> String {
        let targetClient = try client.resolveClient().id
        return try connect(candidate, clientID: targetClient)
    }

    private func connect(_ candidate: Candidate, clientID: String) throws -> String {
        let lock = try FileLock(url: history.lockURL)
        defer { withExtendedLifetime(lock) {} }
        let visits = try history.load()
        let sessionID = try open(candidate, clientID: clientID)
        try history.record(sessionID, host: candidate.host, clientID: clientID, server: client.target.server, visits: visits)
        return sessionID
    }

    private func open(_ candidate: Candidate, clientID targetClient: String) throws -> String {
        if let sessionID = candidate.sessionID {
            do { try client.select(sessionID, clientID: targetClient) }
            catch {
                guard let host = candidate.host else { throw error }
                throw ReshError("Could not show ‘\(candidate.title)’ on \(host.label). Check that this host is connected in the calling Rex app and Remote Control is enabled.\n\(error.localizedDescription)")
            }
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

    @discardableResult
    public func connect(path: String, clientID requestedClient: String? = nil, name: String? = nil, startupCommand: String? = nil) throws -> String {
        let clientID = try requestedClient ?? client.resolveClient().id
        return try connect(Candidate(id: path, kind: name == nil ? .directory : .project,
            title: name ?? "", path: path, startupCommand: startupCommand), clientID: clientID)
    }

    /// The first entry is the last selection made by resh, not inferred app focus.
    @discardableResult
    public func connectLast() throws -> String {
        let clientID = try client.resolveClient().id
        let lock = try FileLock(url: history.lockURL)
        defer { withExtendedLifetime(lock) {} }
        var visits = try history.load()
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
            if snapshots[key] == nil { snapshots[key] = try (host.map(client.at) ?? client).sessions() }
            guard let session = snapshots[key]?.first(where: { $0.sessionID == visit.sessionID }) else {
                visits.removeAll { $0.belongs(to: clientID, server: client.target.server) && $0.candidateID == visit.candidateID }
                continue
            }
            let candidate = Candidate(id: visit.candidateID, kind: .session, title: session.label,
                sessionID: session.sessionID, host: host)
            let id = try open(candidate, clientID: clientID)
            try history.record(id, host: host, clientID: clientID, server: client.target.server, visits: visits)
            return id
        }
        throw ReshError("No previous session in resh's history. Open two sessions through resh first.")
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
        catch { throw ReshError("Created ‘\(label)’, but could not switch Rex to it. Retrying will reuse it.\n\(error.localizedDescription)") }
        return sessionID
    }

    /// Ensures the session is absent; returns a warning only if registry cleanup fails afterwards.
    public func delete(sessionID: String, host: RexHost? = nil) throws -> String? {
        let dataClient = host.map(client.at) ?? client
        let registryKey = host?.id ?? client.target.server
        let lock = try FileLock(url: registry.directory.appendingPathComponent("create.lock"))
        defer { withExtendedLifetime(lock) {} }
        let records = try registry.load()
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
        do {
            try registry.save(records.filter { $0.server != registryKey || $0.sessionID != sessionID })
            return nil
        } catch {
            return "The session is closed, but its registry entry could not be removed.\n\(error.localizedDescription)"
        }
    }
}
