import Foundation
import ReshCore
import Testing

final class TemporaryDirectory: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("resh-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func folder(_ name: String) throws -> String {
        let result = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result.resolvingSymlinksInPath().path
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("sesh-compatible names")
struct NamingTests {
    @Test func plainDirectory() {
        #expect(SessionNamer.name(path: "/work/my.project:one", gitRoot: nil) == "my_project_one")
        #expect(SessionNamer.name(path: "/work/my project", gitRoot: nil) == "my project")
        #expect(SessionNamer.name(path: "/work/проект", gitRoot: nil) == "проект")
        #expect(SessionNamer.name(path: "/", gitRoot: nil) == "root")
    }
    @Test func repositoryAndSubdirectory() {
        #expect(SessionNamer.name(path: "/work/backend", gitRoot: "/work/backend") == "backend")
        #expect(SessionNamer.name(path: "/work/backend/src/api", gitRoot: "/work/backend") == "backend/src/api")
        #expect(SessionNamer.name(path: "/work/backend-other", gitRoot: "/work/backend") == "backend-other")
        #expect(SessionNamer.name(path: "/work/repo/main/src", gitRoot: "/work/repo") == "repo/main/src")
    }
    @Test func realGitAndSymlink() throws {
        let temp = try TemporaryDirectory()
        let repo = try temp.folder("repo.one")
        let nested = try temp.folder("repo.one/src/api")
        let runner = SystemCommandRunner()
        #expect(try runner.run("/usr/bin/git", ["init", "--quiet", repo], timeout: 5).status == 0)
        let link = temp.url.appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: nested)
        #expect(SessionNamer().name(for: nested) == "repo_one/src/api")
        #expect(SessionNamer().name(for: link) == "repo_one/src/api")
    }
    @Test func labelLimit() {
        #expect(SessionNamer.name(path: "/" + String(repeating: "a", count: 200), gitRoot: nil).count == 128)
    }
}

@Suite("Fuzzy search")
struct FuzzyTests {
    let entries = [
        Candidate(id: "1", kind: .session, title: "resh", path: "/personal/resh", sessionID: "s1"),
        Candidate(id: "2", kind: .directory, title: "research", path: "/work/research"),
        Candidate(id: "3", kind: .directory, title: "Привет", path: "/work/Привет"),
    ]
    @Test func emptyQueryKeepsSourceOrder() { #expect(FuzzyMatcher(entries).filter(query: " ").map(\.id) == ["1", "2", "3"]) }
    @Test func fuzzyAndUnicode() {
        let search = FuzzyMatcher(entries + [Candidate(id: "4", kind: .session, title: "café")])
        #expect(search.filter(query: "rsh").first?.title == "resh")
        #expect(search.filter(query: "ПРВ").first?.title == "Привет")
        #expect(search.filter(query: "work res").map(\.id) == ["2"])
        #expect(search.filter(query: "cafe").map(\.id) == ["4"])
        #expect(search.filter(query: "xyz").isEmpty)
        #expect(search.filter(query: "", limit: 1).count == 1)
    }
    @Test func foldersUseHomeRelativePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entry = Candidate(id: "one", kind: .directory, title: "api", path: home + "/work/api")
        #expect(entry.displayTitle == "~/work/api")
        #expect(entry.searchText == "~/work/api This Mac")
    }
    @Test func agentTitlesAndContext() {
        let host = RexHost(id: "build", label: "Build", endpoints: ["https://build.example"])
        let session = Candidate(id: "work", kind: .session, title: "Work", sessionID: "work", host: host)
        let records = [("parser", "opencode", "Fix parser"), ("notes", "codex", "Release notes"),
            ("integration", "new-agent", "OpenCode integration")].map { block, app, title in
            RexAttentionRecord(sessionID: "work", blockID: block, state: "idle",
                updatedAt: "2026-10-31T12:00:00Z", app: app, title: title)
        }
        let search = FuzzyMatcher(RexAgent.panes(in: records, session: session).map(\.candidate))
        #expect(search.filter(query: "code").map(\.blockID) == ["integration"])
        #expect(search.filter(query: "parser").map(\.blockID) == ["parser"])
        #expect(search.filter(query: "work build").count == 3)
    }
    @Test func hostNamesDisambiguateSessionsAndRemotePathsStayRemote() {
        let host = RexHost(id: "host:build", label: "Build", endpoints: ["https://build.example"])
        let local = Candidate(id: "local", kind: .session, title: "api", sessionID: "local")
        let remote = Candidate(id: "remote", kind: .session, title: "api", sessionID: "remote", host: host)
        let search = FuzzyMatcher([local, remote])
        #expect(search.filter(query: "api build").map(\.id) == ["remote"])
        #expect(search.filter(query: "api this mac").map(\.id) == ["local"])
        let path = FileManager.default.homeDirectoryForCurrentUser.path + "/work/api"
        let folder = Candidate(id: "folder", kind: .directory, title: "api", path: path, host: host)
        #expect(folder.displayTitle == path)
    }
}

private final class FakeRunner: CommandRunning, @unchecked Sendable {
    typealias Session = (id: String, label: String, path: String)
    private let lock = NSLock()
    var sessions: [Session] = []
    var serverSessions: [String: [Session]] = [:]
    var adapterFunctions: [String]?
    var adapterVersion = 1
    var sourcePaths: [String] = []
    var catalogHosts: [RexHost] = []
    var catalogWarnings: [String] = []
    var creations = 0
    var startupInputs: [String] = []
    var selections: [String] = []
    var selectionServers: [String] = []
    var rejectSelection = false
    var unavailableServers = Set<String>()
    var clientIDs = ["client:test"]
    var calls: [(String, [String])] = []
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, directory: String?) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        calls.append((executable, arguments))
        func json(_ value: Any) throws -> CommandResult {
            CommandResult(stdout: try JSONSerialization.data(withJSONObject: value))
        }
        if executable == "/usr/bin/git" { return CommandResult(status: 128) }
        let server = arguments[arguments.firstIndex(of: "--server")! + 1]
        if arguments.contains("hosts") {
            return try json(["hosts": catalogHosts.map { ["host": ["id": $0.id, "label": $0.label, "endpoints": $0.endpoints]] },
                             "warnings": catalogWarnings])
        }
        if arguments.contains("actions") {
            return try json(["actions": adapterFunctions == nil ? [] : [
                ["name": "resh_info", "kind": "lua"], ["name": "resh_query", "kind": "lua"],
            ]])
        }
        if arguments.contains("resh_info") { return try json(["version": adapterVersion, "functions": adapterFunctions ?? []]) }
        if arguments.contains("resh_query") {
            let args = try JSONSerialization.jsonObject(with: Data(arguments[arguments.firstIndex(of: "--args")! + 1].utf8)) as! [String: String]
            if args["fn"] == "resolve" { return try json(["results": ["path": args["path"]!]]) }
            return try json(["results": sourcePaths])
        }
        if arguments.contains("ls") {
            if unavailableServers.contains(server) { return CommandResult(status: 1, stderr: Data("Connection timed out".utf8)) }
            return try json(["sessions": (serverSessions[server] ?? sessions).map { ["session_id": $0.id, "label": $0.label] }])
        }
        if let index = arguments.firstIndex(of: "kill") {
            let id = arguments[index + 1]
            if serverSessions[server] != nil { serverSessions[server]?.removeAll { $0.id == id } }
            else { sessions.removeAll { $0.id == id } }
            return try json([:])
        }
        if arguments.contains("client") && arguments.contains("list") {
            return try json(["clients": clientIDs.map { ["client_id": $0, "info": ["kind": "app", "platform": "macos"]] }])
        }
        if arguments.contains("session.create") {
            let object = try JSONSerialization.jsonObject(with: Data(arguments.last!.utf8)) as! [String: Any]
            let windows = object["initial_windows"] as! [[String: Any]]
            let block = (windows[0]["layout"] as! [String: Any])["block"] as! [String: Any]
            let options = block["options"] as! [String: Any]
            let path = options["cwd"] as! String
            if let input = options["initial_input"] as? String { startupInputs.append(input) }
            creations += 1
            let id = "session:\(creations)"
            if serverSessions[server] != nil { serverSessions[server]?.append((id, object["label"] as! String, path)) }
            else { sessions.append((id, object["label"] as! String, path)) }
            return try json(["session_id": id])
        }
        if arguments.contains("session.select") {
            if rejectSelection { return CommandResult(status: 1, stderr: Data("Enable Remote Control".utf8)) }
            let args = try JSONSerialization.jsonObject(with: Data(arguments[arguments.firstIndex(of: "--args")! + 1].utf8)) as! [String: String]
            selections.append(args["session_id"]!)
            selectionServers.append(server)
            return try json([:])
        }
        return CommandResult(stdout: Data())
    }
}

@Suite("Safe Rex session creation")
struct ServiceTests {
    private func service(_ runner: FakeRunner, _ temporary: TemporaryDirectory, clientID: String = "client:test") -> ReshService {
        let tools = Tools(rex: "/fake/rex", zoxide: nil, fd: nil, rexApp: "/fake/Rex.app")
        return ReshService(client: RexClient(tools: tools, target: RexTarget(clientID: clientID, server: "test"), runner: runner),
                           stateURL: temporary.url.appendingPathComponent("state.json"))
    }
    @Test func repeatSelectionReusesSessionEvenAfterCd() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project")
        let service = service(runner, temporary)
        let first = try await service.connect(directory(folder))
        runner.sessions[0].path = "/a/different/current/directory"
        let second = try await service.connect(directory(folder))
        #expect(first == second)
        #expect(runner.creations == 1 && runner.selections.count == 2)
    }
    @Test func selectionFailureDoesNotDuplicateOnRetry() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project")
        let service = service(runner, temporary)
        runner.rejectSelection = true
        await #expect(throws: ReshError.self) { try await service.connect(directory(folder)) }
        runner.rejectSelection = false
        _ = try await service.connect(directory(folder))
        #expect(runner.creations == 1)
    }
    @Test func directoriesReuseSessionNames() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("work/api")
        runner.sessions = [("session:other", "api", "/another/api")]
        let id = try await service(runner, temporary).connect(directory(folder))
        #expect(id == "session:other")
        #expect(runner.creations == 0)
    }
    @Test func renamedSessionsLeaveTheirOldNameAvailable() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project")
        runner.sessions = [("session:existing", "Renamed", folder)]
        #expect(try await service(runner, temporary).connect(directory(folder)) != "session:existing")
        #expect(runner.creations == 1)
    }
    @Test func unsafeCharactersStayData() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project; 'quoted' $HOME")
        _ = try await service(runner, temporary).connect(directory(folder))
        #expect(runner.sessions.last?.path == folder)
        #expect(runner.sessions.last?.label == "project; 'quoted' $HOME")
    }
    @Test func missingDirectoryDoesNotCreateSession() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        await #expect(throws: ReshError.self) {
            try await service(runner, temporary).connect(directory(temporary.url.appendingPathComponent("missing").path))
        }
        #expect(runner.creations == 0)
    }
    @Test func damagedStateIsPreservedBeforeRecordingNewVisits() async throws {
        let temporary = try TemporaryDirectory()
        let url = temporary.url.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: url)
        let runner = FakeRunner()
        let service = service(runner, temporary)
        #expect(service.recentSessionIDs().isEmpty)
        #expect(service.stateError != nil)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: temporary.url,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("state.corrupt-") })
        #expect(try String(contentsOf: backup, encoding: .utf8) == "not json")
        try await service.connect(session("a"))
        #expect(self.service(runner, temporary).recentSessionIDs() == ["a"])
        #expect(service.stateError == nil)
    }
    @Test func projectStartupIsOnlyPartOfNewSessionCreation() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project's folder")
        let service = service(runner, temporary)
        let configuration = try ReshConfiguration.parse("""
        [[session]]
        name = "My project"
        path = "project's folder"
        startup_command = "printf '%s' {}"
        """, directory: temporary.url)
        let first = try await service.connect("project's folder", configuration: configuration, cwd: temporary.url.path)
        let second = try await service.connect("My project", configuration: configuration, cwd: "/")
        #expect(first.sessionID == second.sessionID && runner.creations == 1)
        #expect(first.path == folder && second.path == folder)
        #expect(runner.sessions.first?.label == "My project")
        #expect(runner.startupInputs == ["printf '%s' '" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'\n"])
    }
    @Test func remoteDirectoriesUseTheirServerButSelectTheCallingApp() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let host = RexHost(id: "host:build", label: "build", endpoints: ["https://build.example"])
        runner.serverSessions[host.server] = []
        let service = service(runner, temporary)
        let path = "/srv/project; 'quoted'"
        runner.sessions = [("session:local", "project", path)]
        let candidate = Candidate(id: "remote", kind: .directory, title: "project", path: path, host: host)
        let first = try await service.connect(candidate)
        #expect(try await service.connect(candidate) == first)
        #expect(runner.sessions.map(\.id) == ["session:local"])
        #expect(runner.serverSessions[host.server]?.map(\.path) == [path])
        #expect(runner.creations == 1 && runner.selectionServers == ["test", "test"])
        #expect(runner.startupInputs.isEmpty)
        _ = try await service.delete(sessionID: first, host: host)
        #expect(runner.serverSessions[host.server]?.isEmpty == true)
        #expect(runner.sessions.map(\.id) == ["session:local"])
    }

    @Test(arguments: [false, true])
    func agentNavigationTargetsThePane(_ remote: Bool) async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let host = remote ? RexHost(id: "host:build", label: "build", endpoints: ["https://build.example"]) : nil
        let service = service(runner, temporary)
        let candidate = Candidate(id: RexAgent.identity(sessionID: "work", blockID: "pane", host: host),
            kind: .agent, title: "Work / OC | Task", sessionID: "work", host: host, blockID: "pane", windowID: "tab")
        #expect(try await service.connect(candidate, from: session("previous")) == "work")
        #expect(runner.selections == ["work"] && runner.selectionServers == ["test"])
        let selection = try #require(runner.calls.first { $0.1.contains("session.select") }?.1)
        let argsIndex = try #require(selection.firstIndex(of: "--args"))
        let args = try JSONDecoder().decode([String: String].self, from: Data(selection[argsIndex + 1].utf8))
        #expect(args == ["session_id": "work", "window_id": "tab"])
        let focus = try #require(runner.calls.first { $0.1.contains("session.focus_block") }?.1)
        let serverIndex = try #require(focus.firstIndex(of: "--server"))
        #expect(focus[serverIndex + 1] == (host?.server ?? "test"))
        #expect(try JSONDecoder().decode([String: String].self, from: Data(focus.last!.utf8))
            == ["session_id": "work", "block_id": "pane"])
        #expect(service.recentSessionIDs() == ["work", "previous"])
    }

    private func directory(_ path: String) -> Candidate {
        Candidate(id: path, kind: .directory, title: "", path: path)
    }

    private func session(_ id: String, host: RexHost? = nil) -> Candidate {
        Candidate(id: Candidate.identity(id, host: host), kind: .session, title: "Session", sessionID: id, host: host)
    }

    @Test func sessionStateSurvivesRestart() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        runner.sessions = [("a", "A", "/a"), ("b", "B", "/b")]
        let first = service(runner, temporary)
        first.togglePin(sessionID: "a")
        first.togglePin(sessionID: "b")
        try await first.connect(session("b"), from: session("a"))
        try await first.connect(session("b"), from: session("b"))
        let reopened = first.at(first.target)
        #expect(reopened.recentSessionIDs() == ["b", "a"])
        #expect(reopened.pinnedSessionIDs() == ["a", "b"])
        reopened.togglePin(sessionID: "a")
        #expect(try await reopened.connectLast() == "a")
        #expect(reopened.recentSessionIDs() == ["a", "b"])
        #expect(try await reopened.connectLast() == "b")
        let restarted = service(runner, temporary)
        #expect(restarted.recentSessionIDs() == ["b", "a"])
        #expect(restarted.pinnedSessionIDs() == ["b"])
        restarted.togglePin(sessionID: "a")
        await restarted.recordVisit(sessionID: "a", observedAt: .now, initial: true)
        #expect(restarted.recentSessionIDs() == ["a", "b"])
        #expect(try await restarted.connectLast(from: session("a")) == "b")
        let saved = service(runner, temporary)
        #expect(saved.recentSessionIDs() == ["b", "a"])
        #expect(saved.pinnedSessionIDs() == ["b", "a"])
        #expect(runner.creations == 0)
    }

    @Test func failedSelectionsKeepHistory() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        runner.sessions = [("a", "A", "/a"), ("b", "B", "/b"), ("c", "C", "/c")]
        let service = service(runner, temporary)
        try await service.connect(session("a"))
        try await service.connect(session("b"))
        runner.rejectSelection = true
        await #expect(throws: ReshError.self) { try await service.connect(session("c"), from: session("a")) }
        await #expect(throws: ReshError.self) { try await service.connectLast(from: session("c")) }
        #expect(service.recentSessionIDs() == ["b", "a"])
        #expect(self.service(runner, temporary).recentSessionIDs() == ["b", "a"])
        runner.rejectSelection = false
        #expect(try await service.connectLast() == "a")
    }

    @Test(arguments: [false, true])
    func delayedFocusObservationsKeepTheConfirmedSelection(_ initial: Bool) async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let service = service(runner, temporary)
        let observedAt = ContinuousClock.now
        try await service.connect(session("b"), from: session("a"))
        await service.recordVisit(sessionID: "a", observedAt: observedAt, initial: initial)
        #expect(service.recentSessionIDs() == ["b", "a"])
    }

    @Test func unavailableStateStorageKeepsSessionChangesUsable() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let directory = temporary.url.appendingPathComponent("state")
        try Data().write(to: directory)
        let service = ReshService(client: RexClient(tools: Tools(rex: "/fake/rex", zoxide: nil, fd: nil, rexApp: "/fake/Rex.app"),
            target: RexTarget(clientID: "client:test", server: "test"), runner: runner),
            stateURL: directory.appendingPathComponent("state.json"))
        service.togglePin(sessionID: "a")
        try await service.connect(session("a"))
        #expect(service.recentSessionIDs() == ["a"])
        #expect(service.pinnedSessionIDs() == ["a"])
        #expect(service.stateError != nil)
        try FileManager.default.removeItem(at: directory)
        try await service.connect(session("b"))
        #expect(service.stateError == nil)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: try #require(service.stateURL))) as? [String: Any]
        #expect(saved?["recentSessions"] as? [String] == ["b", "a"])
        #expect(saved?["pinnedSessions"] as? [String] == ["a"])
    }

    @Test(arguments: ["a", "b", "c"])
    func previousSessionUsesCallingSession(_ current: String) async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        runner.sessions = [("a", "A", "/a"), ("b", "B", "/b"), ("c", "C", "/c")]
        let service = service(runner, temporary)
        try await service.connect(session("b"), from: session("a"))
        let previous = current == "b" ? "a" : "b"
        #expect(try await service.connectLast(from: session(current)) == previous)
        #expect(try await service.connectLast(from: session(previous)) == current)
        #expect(runner.selections.suffix(2) == [previous, current])
    }

    @Test func previousSessionSkipsClosedSessions() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        runner.sessions = [("a", "A", "/a"), ("b", "B", "/b"), ("c", "C", "/c"), ("d", "D", "/d")]
        let service = service(runner, temporary)
        for id in ["a", "b", "c"] { try await service.connect(session(id)) }
        runner.sessions.removeAll { $0.id == "b" }
        #expect(try await service.connectLast() == "a")
        #expect(service.recentSessionIDs() == ["a", "c"])
        #expect(try await service.connectLast() == "c")
        try await service.delete(sessionID: "c")
        #expect(service.recentSessionIDs() == ["a"])
        #expect(try await service.connectLast(from: session("d")) == "a")
        #expect(try await service.connectLast(from: session("a")) == "d")
    }

    @Test func clientsShareHistoryAndSwitchIndependently() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        runner.clientIDs = ["client:test", "client:other"]
        runner.sessions = [("a", "A", "/a"), ("b", "B", "/b"), ("c", "C", "/c")]
        let first = service(runner, temporary)
        let other = first.at(RexTarget(clientID: "client:other", server: "test"))
        try await first.connect(session("a"))
        try await other.connect(session("b"))
        try await first.connect(session("c"))
        #expect(first.recentSessionIDs() == ["c", "b", "a"])
        #expect(other.recentSessionIDs() == first.recentSessionIDs())
        #expect(try await other.connectLast(from: session("b")) == "c")
        let selection = try #require(runner.calls.last { $0.1.contains("session.select") }?.1)
        #expect(selection[selection.firstIndex(of: "-C")! + 1] == "client:other")
        #expect(try await first.connectLast(from: session("a")) == "c")
    }

    @Test func previousSessionResolvesLocalAndRemoteSessions() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let host = RexHost(id: "host:build", label: "build", endpoints: ["https://build.example"])
        runner.catalogHosts = [host]
        runner.sessions = [("local", "Session", "/local")]
        runner.serverSessions[host.server] = [("remote", "Session", "/remote")]
        let service = service(runner, temporary)
        try await service.connect(session("local"))
        try await service.connect(session("remote", host: host))
        #expect(service.recentSessionIDs() == ["remote", "local"])
        try await service.connectLast()
        #expect(service.recentSessionIDs() == ["local", "remote"])
        try await service.connectLast()
        #expect(service.recentSessionIDs() == ["remote", "local"])
        #expect(runner.selectionServers == ["test", "test", "test", "test"])
    }

    @Test(arguments: ["sessions", "catalog"])
    func unavailablePreviousSessionKeepsHistory(_ failure: String) async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let host = RexHost(id: "host:build", label: "build", endpoints: ["https://build.example"])
        runner.catalogHosts = [host]
        runner.sessions = [("local", "Local", "/local")]
        runner.serverSessions[host.server] = [("remote", "Remote", "/remote")]
        let service = service(runner, temporary)
        let remote = try service.session("remote")
        try await service.connect(session("local"), from: remote)
        if failure == "sessions" { runner.unavailableServers.insert(host.server) }
        else { runner.catalogHosts = []; runner.catalogWarnings = ["Home is unavailable"] }
        await #expect(throws: ReshError.self) { try await service.connectLast(from: session("local")) }
        #expect(service.recentSessionIDs() == ["local", "remote"])
        #expect(runner.selections == ["local"])
        runner.unavailableServers = []; runner.catalogHosts = [host]; runner.catalogWarnings = []
        #expect(try await service.connectLast(from: session("local")) == "remote")
        let alias = RexHost(id: "host:alias", label: "alias", endpoints: host.endpoints)
        runner.catalogHosts = [alias, host]
        runner.serverSessions[alias.server] = runner.serverSessions[host.server]
        #expect(try await service.connectLast(from: session("remote", host: alias)) == "local")
        #expect(try await service.connectLast(from: session("local")) == "remote")
        #expect(service.recentSessionIDs() == ["remote", "local"])
    }
}

@Suite("Optional remote sources")
struct RemoteSourceTests {
    private func remote(_ runner: FakeRunner) -> RexRemote {
        RexRemote(client: RexClient(tools: Tools(rex: "/fake/rex", zoxide: nil, fd: nil, rexApp: "/fake/Rex.app"),
            target: RexTarget(server: "build"), runner: runner))
    }
    @Test func anUnconfiguredHostNeedsNoSourceCommands() throws {
        let runner = FakeRunner()
        #expect(try remote(runner).functions().isEmpty)
        #expect(!runner.calls.contains { $0.1.contains("do") })
    }
    @Test func hostAliasesKeepUsableCatalogEntriesAndWarnings() throws {
        let runner = FakeRunner()
        let first = RexHost(id: "host:first", label: "build", endpoints: ["https://build.example"])
        runner.catalogHosts = [first, RexHost(id: "host:alias", label: "alias", endpoints: first.endpoints)]
        runner.catalogWarnings = ["Home is unavailable; using saved hosts"]
        let catalog = try RexHostCatalog(client: remote(runner).client).read()
        #expect(catalog.hosts == [first])
        #expect(catalog.warnings == runner.catalogWarnings)
    }
    @Test func capabilityVersions() throws {
        let runner = FakeRunner()
        runner.adapterFunctions = ["zoxide", "resolve", "future"]
        #expect(try remote(runner).functions() == ["zoxide", "resolve", "future"])
        runner.adapterVersion = 2
        #expect(throws: ReshError.self) { try remote(runner).functions() }
    }
    @Test func remotePathsAreNotCheckedAgainstTheClientFilesystem() throws {
        let runner = FakeRunner(), host = RexHost(id: "host:build", label: "build", endpoints: ["https://build.example"])
        runner.sourcePaths = ["/srv/api", "/srv/api/"]
        let entries = try remote(runner).paths(function: "zoxide", host: host)
        #expect(entries.count == 1 && entries[0].path == "/srv/api" && entries[0].host == host)
        runner.sourcePaths = []
        #expect(try remote(runner).paths(function: "zoxide", host: host).isEmpty)
        runner.sourcePaths = ["~/api"]
        #expect(throws: ReshError.self) { try remote(runner).paths(function: "zoxide", host: host) }
    }
}
