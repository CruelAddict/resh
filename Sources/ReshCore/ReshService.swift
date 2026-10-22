import Foundation

public actor ReshService {
    private let client: RexClient
    private let registry: SessionRegistry
    public init(client: RexClient, registry: SessionRegistry = SessionRegistry()) {
        self.client = client; self.registry = registry
    }

    public func catalog(find: Bool = false) throws -> Catalog {
        let sessions = try sessionCandidates()
        let directories = try directoryCatalog(find: find)
        return Catalog(sessions: sessions, directories: directories.directories, warnings: directories.warnings)
    }

    public func directoryCatalog(find: Bool = false) throws -> Catalog {
        var warnings = [String]()
        var paths = [String]()
        if find {
            guard let fd = client.tools.fd else { throw ReshError("Find folders needs fd. Install it with brew install fd.") }
            let result = try client.runner.run(fd, ["-H", "-d", "2", "-t", "d", "-E", ".Trash", "--print0", ".",
                FileManager.default.homeDirectoryForCurrentUser.path], timeout: 12)
            if result.status != 0 { warnings.append("Folder search was incomplete. Some directories may be inaccessible.") }
            paths = result.text.split(separator: "\0").prefix(20_000).map(String.init)
        } else if let zoxide = client.tools.zoxide {
            let result = try client.runner.run(zoxide, ["query", "-l"], timeout: 5)
            if result.status == 0 { paths = result.text.split(separator: "\n").map(String.init) }
            else { warnings.append("No zoxide history yet. Use Find folders (⌘4).") }
        } else { warnings.append("zoxide not found. Use Find folders (⌘4), or install zoxide.") }
        return Catalog(directories: PathIdentity.directories(paths), warnings: warnings)
    }

    public func sessionCandidates() throws -> [Candidate] {
        Self.candidates(from: try client.sessions())
    }

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
        return try connect(path: path, clientID: targetClient)
    }

    @discardableResult
    public func connect(path: String, clientID requestedClient: String? = nil) throws -> String {
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
        let base = SessionNamer(runner: client.runner, git: client.tools.git).name(for: path)
        // An unregistered session's current tab directory is not its identity.
        // Only resh's explicit creation records can associate a folder with a session.
        let label = SessionNamer.availableName(base: base, path: path, occupied: Set(sessions.map(\.label)))
        let reply = try client.api("session.create", ["label": label, "initial_windows": [[
            "window_label": "Terminal",
            "layout": ["block": ["flavor": "com.superlogical.terminal.shell", "options": ["cwd": path]]],
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

    public func delete(sessionID: String) throws {
        _ = try client.command(["kill", sessionID])
        let lock = try FileLock(url: registry.directory.appendingPathComponent("create.lock"))
        defer { withExtendedLifetime(lock) {} }
        try registry.save(registry.load().filter { $0.server != client.target.server || $0.sessionID != sessionID })
    }
}
