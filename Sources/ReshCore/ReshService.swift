import Foundation

public actor ReshService {
    private let client: RexClient
    private let registry: SessionRegistry
    public init(client: RexClient, registry: SessionRegistry = SessionRegistry()) {
        self.client = client; self.registry = registry
    }

    public nonisolated var target: RexTarget { client.target }

    public nonisolated static func candidates(from sessions: [RexSession]) -> [Candidate] {
        // A Rex session has no global working directory. Do not inspect its tabs.
        sessions.map { Candidate(id: $0.sessionID, kind: .session, title: $0.label, sessionID: $0.sessionID) }
    }

    public func resolveClient() throws -> (id: String, pid: Int32?) { try client.resolveClient() }

    /// Paths are sent as JSON arguments, never interpolated into a shell command.
    @discardableResult
    public func connect(_ candidate: Candidate) throws -> String {
        let targetClient = try client.resolveClient().id
        if let sessionID = candidate.sessionID {
            try client.select(sessionID, clientID: targetClient)
            return sessionID
        }
        guard let path = candidate.path else { throw ReshError("The selected folder has no path.") }
        return try connect(path: path, clientID: targetClient, name: candidate.kind == .project ? candidate.title : nil,
                           startupCommand: candidate.startupCommand)
    }

    @discardableResult
    public func connect(path: String, clientID requestedClient: String? = nil, name: String? = nil, startupCommand: String? = nil) throws -> String {
        let clientID = try requestedClient ?? client.resolveClient().id
        let path = PathIdentity.canonical(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReshError("This folder no longer exists: \(path)")
        }
        let lock = try FileLock(url: registry.directory.appendingPathComponent("create.lock"))
        defer { withExtendedLifetime(lock) {} }
        let sessions = try client.sessions()
        let liveIDs = Set(sessions.map(\.sessionID))
        var records = try registry.load().filter { $0.server != client.target.server || liveIDs.contains($0.sessionID) }
        if let record = records.first(where: { $0.server == client.target.server && $0.path == path }) {
            try client.select(record.sessionID, clientID: clientID)
            return record.sessionID
        }
        let base = name ?? SessionNamer(runner: client.runner, git: client.tools.git).name(for: path)
        // An unregistered session's current tab directory is not its identity.
        // Only resh's explicit creation records can associate a folder with a session.
        let label = SessionNamer.availableName(base: base, path: path, occupied: Set(sessions.map(\.label)))
        var options: [String: Any] = ["cwd": path]
        if let startupCommand, !startupCommand.isEmpty {
            let quotedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            options["initial_input"] = startupCommand.replacingOccurrences(of: "{}", with: quotedPath) + "\n"
        }
        let reply = try client.api("session.create", ["label": label, "initial_windows": [[
            "window_label": "Terminal",
            "layout": ["block": ["flavor": "com.superlogical.terminal.shell", "options": options]],
        ]]])
        struct Created: Decodable { let session_id: String }
        let sessionID = try JSONDecoder().decode(Created.self, from: reply).session_id
        // Save before selecting: if Remote Control is disabled, retrying must not duplicate a session.
        records.append(SessionRecord(server: client.target.server, path: path, sessionID: sessionID))
        try registry.save(records)
        do { try client.select(sessionID, clientID: clientID) }
        catch { throw ReshError("Created ‘\(label)’, but could not switch Rex to it. Retrying will reuse it.\n\(error.localizedDescription)") }
        if let zoxide = client.tools.zoxide { _ = try? client.runner.run(zoxide, ["add", path], timeout: 3) }
        return sessionID
    }

    /// Ensures the session is absent; returns a warning only if registry cleanup fails afterwards.
    public func delete(sessionID: String) throws -> String? {
        let lock = try FileLock(url: registry.directory.appendingPathComponent("create.lock"))
        defer { withExtendedLifetime(lock) {} }
        let records = try registry.load()
        do {
            _ = try client.command(["kill", sessionID])
        } catch {
            let deletionError = error
            let sessions: [RexSession]
            do { sessions = try client.sessions() }
            catch {
                throw ReshError("Could not confirm whether the session was closed.\n\(deletionError.localizedDescription)\n\(error.localizedDescription)")
            }
            if sessions.contains(where: { $0.sessionID == sessionID }) { throw deletionError }
        }
        do {
            try registry.save(records.filter { $0.server != client.target.server || $0.sessionID != sessionID })
            return nil
        } catch {
            return "The session is closed, but its registry entry could not be removed.\n\(error.localizedDescription)"
        }
    }
}
