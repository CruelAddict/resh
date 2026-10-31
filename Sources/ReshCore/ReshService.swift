import Foundation

public actor ReshService {
    private let client: RexClient
    private let state: SessionState
    public init(client: RexClient, stateURL: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/resh/state.json")) {
        self.client = client
        self.state = SessionState(url: stateURL)
    }

    private init(client: RexClient, state: SessionState) {
        self.client = client; self.state = state
    }

    public nonisolated func at(_ target: RexTarget) -> ReshService {
        ReshService(client: client.at(target), state: state)
    }

    public nonisolated var target: RexTarget { client.target }
    public nonisolated func hosts() throws -> (hosts: [RexHost], warnings: [String]) {
        let catalog = try RexHostCatalog(client: client).read()
        client.apiCaller?.updateHosts(catalog.hosts)
        return catalog
    }
    public nonisolated func remote(_ host: RexHost) -> RexRemote { RexRemote(client: client.at(host)) }
    public nonisolated func sessions(host: RexHost? = nil, timeout: TimeInterval = 5) throws -> [RexSession] { try (host.map(client.at) ?? client).sessions(timeout: timeout) }

    public nonisolated static func candidates(from sessions: [RexSession], host: RexHost? = nil) -> [Candidate] {
        // A Rex session has no global working directory. Do not inspect its tabs.
        sessions.map { Candidate(id: Candidate.identity($0.sessionID, host: host), kind: .session, title: $0.label, sessionID: $0.sessionID, host: host) }
    }

    public func resolveClient() throws -> (id: String, rexAppPID: Int32?) { try client.resolveClient() }

    public func perform(_ invocation: KeyInvocation, sessionID: String?) throws {
        try Task.checkCancellation()
        let clientID = try client.target.clientID ?? client.resolveClient().id
        let args = String(decoding: try JSONEncoder().encode(invocation.args), as: UTF8.self)
        var arguments = ["-C", clientID, "do", "--args", args, "--json"]
        if let sessionID { arguments += ["-s", sessionID] }
        _ = try client.command(arguments + ["--", invocation.action], timeout: 30)
    }

    public nonisolated var stateURL: URL? { state.url }
    public nonisolated var stateError: String? { state.error }

    public nonisolated func recentSessionIDs() -> [String] {
        state.withState { $0.visits.map(\.sessionID) }
    }

    public nonisolated func pinnedSessionIDs() -> [String] {
        state.withState { $0.pins }
    }

    @discardableResult
    public nonisolated func togglePin(sessionID: String) -> [String] {
        state.withState { content in
            if content.pins.contains(sessionID) { content.pins.removeAll { $0 == sessionID } }
            else { content.pins.append(sessionID) }
            return content.pins
        }
    }

    /// A complete catalog prunes missing pins and history restored before this process's first visit.
    public func reconcileState(sessionIDs: Set<String>) {
        guard !Task.isCancelled else { return }
        state.withState { content in
            content.visits.removeAll { $0.selectedAt == nil && !sessionIDs.contains($0.sessionID) }
            content.pins.removeAll { !sessionIDs.contains($0) }
        }
    }

    public func recordVisit(sessionID: String, observedAt: ContinuousClock.Instant, initial: Bool) {
        state.withState { content in
            // Restored order can be reconciled with initial focus; commands confirmed
            // during this launch take precedence over a delayed initial read.
            if initial, content.visits.first?.selectedAt != nil { return }
            SessionState.record(sessionID, at: observedAt, visits: &content.visits)
        }
    }

    public nonisolated func session(_ sessionID: String, candidates: [Candidate] = []) throws -> Candidate {
        let matches = candidates.filter { $0.sessionID == sessionID }
        if matches.count == 1 { return matches[0] }
        guard matches.isEmpty else { throw ReshError("Cannot identify the current Rex session's host.") }
        if let session = try sessions().first(where: { $0.sessionID == sessionID }) {
            return Self.candidates(from: [session])[0]
        }
        for host in try hosts().hosts {
            if let session = try? sessions(host: host).first(where: { $0.sessionID == sessionID }) {
                return Self.candidates(from: [session], host: host)[0]
            }
        }
        throw ReshError("Cannot identify the current Rex session's host.")
    }

    public nonisolated func forgetSession(sessionID: String) {
        state.withState { content in
            content.visits.removeAll { $0.sessionID == sessionID }
            content.pins.removeAll { $0 == sessionID }
        }
    }

    public func connect(_ path: String, configuration: ReshConfiguration, cwd: String, from current: Candidate? = nil) throws -> (sessionID: String, path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path
        let directory = PathIdentity.canonical(absolute)
        let project = configuration.projects.first { $0.name == path } ?? configuration.project(at: directory)
        let candidate = project?.candidate ?? Candidate(id: directory, kind: .directory,
            title: directory, path: directory, startupCommand: configuration.defaultStartupCommand)
        let sessionID = try connect(candidate, from: current)
        return (sessionID, project?.path ?? directory)
    }

    /// Paths are sent as JSON arguments, never interpolated into a shell command.
    @discardableResult
    public func connect(_ candidate: Candidate, from current: Candidate? = nil) throws -> String {
        try state.withState { content in
            let targetClient: String
            if candidate.sessionID != nil, let knownClient = client.target.clientID { targetClient = knownClient }
            else { targetClient = try client.resolveClient().id }
            let sessionID = try open(candidate, clientID: targetClient)
            SessionState.record(sessionID, from: current?.sessionID, visits: &content.visits)
            return sessionID
        }
    }

    /// A plain session uses Rex's default shell directory, with no folder identity or startup input.
    public func createSession(name: String, host: RexHost? = nil) throws -> String {
        _ = try client.resolveClient()
        let dataClient = host.map(client.at) ?? client
        let reply = try dataClient.api("session.create", ["label": name, "initial_windows": [[
            "window_label": "Terminal",
            "layout": ["block": ["flavor": "com.superlogical.terminal.shell", "options": [:]]],
        ]]])
        struct Created: Decodable { let session_id: String }
        return try JSONDecoder().decode(Created.self, from: reply).session_id
    }

    private func open(_ candidate: Candidate, clientID targetClient: String) throws -> String {
        if let sessionID = candidate.sessionID {
            try client.select(sessionID, clientID: targetClient, windowID: candidate.windowID)
            if let blockID = candidate.blockID {
                _ = try (candidate.host.map(client.at) ?? client).api("session.focus_block", ["session_id": sessionID, "block_id": blockID])
            }
            return sessionID
        }
        guard let rawPath = candidate.path else { throw ReshError("The selected folder has no path.") }
        if let host = candidate.host {
            let remote = client.at(host)
            let directory = try RexRemote(client: remote).directory(rawPath)
            return try create(path: directory.path, clientID: targetClient, name: directory.name,
                              startupCommand: nil, dataClient: remote)
        }
        let path = PathIdentity.canonical(rawPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReshError("This folder no longer exists: \(path)")
        }
        let id = try create(path: path, clientID: targetClient,
            name: candidate.kind == .project ? candidate.title : SessionNamer(runner: client.runner, git: client.tools.git).name(for: path),
            startupCommand: candidate.startupCommand, dataClient: client)
        if let zoxide = client.tools.zoxide { _ = try? client.runner.run(zoxide, ["add", path], timeout: 3) }
        return id
    }

    /// An explicit calling session takes precedence over the last recorded selection.
    @discardableResult
    public func connectLast(from current: Candidate? = nil) throws -> String? {
        try state.withState { content in
            let clientID = try client.target.clientID ?? client.resolveClient().id
            let currentID = current?.sessionID ?? content.visits.first?.sessionID
            let previous = content.visits.filter { $0.sessionID != currentID }
            var catalog: (hosts: [RexHost], warnings: [String])?, snapshots: [String: [RexSession]] = [:]
            for visit in previous {
                guard let candidate = try previousSession(visit.sessionID, catalog: &catalog, snapshots: &snapshots) else {
                    content.visits.removeAll { $0.sessionID == visit.sessionID }
                    continue
                }
                let id = try open(candidate, clientID: clientID)
                SessionState.record(id, from: current?.sessionID, visits: &content.visits)
                return id
            }
            return nil
        }
    }

    private func previousSession(_ id: String, catalog: inout (hosts: [RexHost], warnings: [String])?,
                                 snapshots: inout [String: [RexSession]]) throws -> Candidate? {
        if snapshots[client.target.server] == nil { snapshots[client.target.server] = try sessions() }
        if let session = snapshots[client.target.server]?.first(where: { $0.sessionID == id }) {
            return Self.candidates(from: [session])[0]
        }
        if catalog == nil { catalog = try hosts() }
        var unavailable: Error?
        for host in catalog?.hosts ?? [] {
            do {
                if snapshots[host.id] == nil { snapshots[host.id] = try sessions(host: host, timeout: 2) }
                if let session = snapshots[host.id]?.first(where: { $0.sessionID == id }) {
                    return Self.candidates(from: [session], host: host)[0]
                }
            } catch { unavailable = error }
        }
        if let unavailable { throw unavailable }
        if catalog?.warnings.isEmpty == false {
            throw ReshError("Cannot confirm whether the previous session still exists.\n" + (catalog?.warnings.joined(separator: "\n") ?? ""))
        }
        return nil
    }

    private func create(path: String, clientID: String, name: String, startupCommand: String?,
                        dataClient: RexClient) throws -> String {
        let sessions = try dataClient.sessions()
        if let existing = sessions.first(where: { $0.label == name }) {
            try client.select(existing.sessionID, clientID: clientID)
            return existing.sessionID
        }
        var options: [String: Any] = ["cwd": path]
        if let startupCommand, !startupCommand.isEmpty {
            let quotedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            options["initial_input"] = startupCommand.replacingOccurrences(of: "{}", with: quotedPath) + "\n"
        }
        let reply = try dataClient.api("session.create", ["label": name, "initial_windows": [[
            "window_label": "Terminal",
            "layout": ["block": ["flavor": "com.superlogical.terminal.shell", "options": options]],
        ]]])
        struct Created: Decodable { let session_id: String }
        let sessionID = try JSONDecoder().decode(Created.self, from: reply).session_id
        do { try client.select(sessionID, clientID: clientID) }
        catch {
            throw ReshError("Created ‘\(name)’, but could not switch Rex to it. Retrying will reuse it.\n\(error.localizedDescription)",
                userMessage: (error as? ReshError)?.userMessage)
        }
        return sessionID
    }

    /// A successful return confirms absence.
    public func delete(sessionID: String, host: RexHost? = nil) throws {
        let dataClient = host.map(client.at) ?? client
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
        forgetSession(sessionID: sessionID)
    }
}
