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
    @Test func collisionsDoNotMergeProjects() {
        #expect(SessionNamer.availableName(base: "api", path: "/work/api", occupied: ["api"]) == "work/api")
        let name = SessionNamer.availableName(base: "api", path: "/work/api", occupied: ["api", "work/api"])
        #expect(name.hasPrefix("api-"))
        #expect(name == SessionNamer.availableName(base: "api", path: "/work/api", occupied: ["api", "work/api"]))
        #expect(SessionNamer.availableName(base: "api", path: "/work/api", occupied: ["api", "work/api", name]) == name + "-2")
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
        #expect(entry.searchText == "~/work/api")
    }
}

@Suite("Rex theme sync")
struct ThemeTests {
    @Test func builtInPalette() throws {
        let data = Data("""
        [{"id":"charcoal","name":"Charcoal","source":{"background":"#121113","foreground":"#f8f8f2",
        "selectionBackground":"#444444","ansi":["#000000","#000000","#000000","#000000","#aabbcc"]}}]
        """.utf8)
        let theme = RexTheme.resolve(preferences: ["Workspace.appearance": "dark", "Workspace.interfaceStyle": "blendTheme",
            "Workspace.darkThemeID": "charcoal"], builtins: data, systemIsDark: false)
        #expect(theme.name == "Charcoal")
        #expect(theme.background.hex == "#121113")
        #expect(theme.foreground.hex == "#f8f8f2")
        #expect(theme.accent.hex == "#aabbcc")
        #expect(theme.usesGlass && theme.usesTint && theme.isDark)
    }
    @Test func customPaletteAndClassic() throws {
        let custom = Data("""
        [{"id":"custom-1","name":"Mine","palette":{"background":{"red":0.2,"green":0.4,"blue":0.6,"alpha":1}}}]
        """.utf8)
        let theme = RexTheme.resolve(preferences: ["Workspace.appearance": "light", "Workspace.interfaceStyle": "useTheme",
            "Workspace.lightThemeID": "custom-1", "Workspace.customThemes": custom], builtins: nil, systemIsDark: true)
        #expect(theme.name == "Mine")
        #expect(theme.background.hex == "#336699")
        #expect(!theme.isDark && !theme.usesGlass && theme.usesTint)
    }
    @Test func malformedDataFallsBack() {
        let theme = RexTheme.resolve(preferences: ["Workspace.customThemes": Data("bad".utf8)],
                                    builtins: Data("broken".utf8), systemIsDark: true)
        #expect(theme.name == "System" && theme.isDark)
        #expect(RGBA(hex: "#gggggg") == nil)
    }
    @Test func usesRexUISemanticsNotTerminalAnsiBlue() {
        let data = Data("""
        [{"id":"native","source":{"background":"#161616","selectionBackground":"#3a3835",
        "ansi":["#000000","#000000","#000000","#000000","#8aa0b4"]},
        "semantic":{"accentSolid":"#e05d3a","selection":"#e05d3a","surfaceRaised":"#262626","info":"#8aa0b4"}}]
        """.utf8)
        let theme = RexTheme.resolve(preferences: ["Workspace.darkThemeID": "native"], builtins: data, systemIsDark: true)
        #expect(theme.accent.hex == "#e05d3a")
        #expect(theme.selection.hex == "#e05d3a")
        #expect(theme.panelBackground.hex == "#262626")
        #expect(theme.attentionColor.hex == "#8aa0b4")
    }
}

private final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    var sessions: [(id: String, label: String, path: String)] = []
    var creations = 0
    var startupInputs: [String] = []
    var selections: [String] = []
    var rejectSelection = false
    var calls: [(String, [String])] = []
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, directory: String?) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        calls.append((executable, arguments))
        func json(_ value: Any) throws -> CommandResult {
            CommandResult(stdout: try JSONSerialization.data(withJSONObject: value))
        }
        if executable == "/usr/bin/git" { return CommandResult(status: 128) }
        if arguments.contains("ls") {
            return try json(["sessions": sessions.map { ["session_id": $0.id, "label": $0.label] }])
        }
        if arguments.contains("client") && arguments.contains("list") {
            return try json(["clients": [["client_id": "client:test", "info": ["kind": "app", "platform": "macos"]]]])
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
            sessions.append((id, object["label"] as! String, path))
            return try json(["session_id": id])
        }
        if arguments.contains("session.select") {
            if rejectSelection { return CommandResult(status: 1, stderr: Data("Enable Remote Control".utf8)) }
            let args = try JSONSerialization.jsonObject(with: Data(arguments[arguments.firstIndex(of: "--args")! + 1].utf8)) as! [String: String]
            selections.append(args["session_id"]!)
            return try json([:])
        }
        return CommandResult(stdout: Data())
    }
}

@Suite("Safe Rex session creation")
struct ServiceTests {
    private func service(_ runner: FakeRunner, _ temporary: TemporaryDirectory) -> ReshService {
        let tools = Tools(rex: "/fake/rex", zoxide: nil, fd: nil, rexApp: "/fake/Rex.app")
        return ReshService(client: RexClient(tools: tools, target: RexTarget(clientID: "client:test", server: "test"), runner: runner),
                           registry: SessionRegistry(directory: temporary.url.appendingPathComponent("registry")))
    }
    @Test func repeatSelectionReusesSessionEvenAfterCd() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project")
        let service = service(runner, temporary)
        let first = try await service.connect(path: folder)
        runner.sessions[0].path = "/a/different/current/directory"
        let second = try await service.connect(path: folder)
        #expect(first == second)
        #expect(runner.creations == 1 && runner.selections.count == 2)
    }
    @Test func selectionFailureDoesNotDuplicateOnRetry() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project")
        let service = service(runner, temporary)
        runner.rejectSelection = true
        await #expect(throws: ReshError.self) { try await service.connect(path: folder) }
        runner.rejectSelection = false
        _ = try await service.connect(path: folder)
        #expect(runner.creations == 1)
    }
    @Test func nameCollisionDoesNotSelectWrongDirectory() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("work/api")
        runner.sessions = [("session:other", "api", "/another/api")]
        let id = try await service(runner, temporary).connect(path: folder)
        #expect(id != "session:other")
        #expect(runner.sessions.last?.label == "work/api")
    }
    @Test func unregisteredSessionsRemainIndependent() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project")
        runner.sessions = [("session:existing", "project", folder)]
        #expect(try await service(runner, temporary).connect(path: folder) != "session:existing")
        #expect(runner.creations == 1)
    }
    @Test func unsafeCharactersStayData() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project; 'quoted' $HOME")
        _ = try await service(runner, temporary).connect(path: folder)
        #expect(runner.sessions.last?.path == folder)
        #expect(runner.sessions.last?.label == "project; 'quoted' $HOME")
    }
    @Test func missingDirectoryDoesNotCreateSession() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        await #expect(throws: ReshError.self) {
            try await service(runner, temporary).connect(path: temporary.url.appendingPathComponent("missing").path)
        }
        #expect(runner.creations == 0)
    }
    @Test func corruptRegistryDoesNotLoseIdentity() throws {
        let temporary = try TemporaryDirectory()
        let registry = SessionRegistry(directory: temporary.url)
        try Data("not json".utf8).write(to: registry.url)
        #expect(throws: ReshError.self) { try registry.load() }
    }
    @Test(arguments: [0, 1, 100]) func listingUsesOneRequest(_ count: Int) async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        runner.sessions = (0..<count).map { ("session:\($0)", "session-\($0)", "/irrelevant/tab/path") }
        let sessions = try await service(runner, temporary).sessionCandidates()
        #expect(sessions.map(\.title) == runner.sessions.map(\.label))
        #expect(runner.calls.count == 1)
    }
    @Test func projectStartupIsOnlyPartOfNewSessionCreation() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project's folder")
        let service = service(runner, temporary)
        let candidate = Candidate(id: folder, kind: .project, title: "My project", path: folder, startupCommand: "printf '%s' {}")
        let first = try await service.connect(candidate)
        let second = try await service.connect(candidate)
        #expect(first == second && runner.creations == 1)
        #expect(runner.sessions.first?.label == "My project")
        #expect(runner.startupInputs == ["printf '%s' '" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'\n"])
    }
}
