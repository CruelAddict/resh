import Foundation
import ReshCore
import Testing

private final class TemporaryDirectory: @unchecked Sendable {
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
    @Test func emptyQueryKeepsSourceOrder() { #expect(FuzzyMatcher.filter(entries, query: " ").map(\.id) == ["1", "2", "3"]) }
    @Test func fuzzyAndUnicode() {
        #expect(FuzzyMatcher.filter(entries, query: "rsh").first?.title == "resh")
        #expect(FuzzyMatcher.filter(entries, query: "ПРВ").first?.title == "Привет")
        #expect(FuzzyMatcher.filter(entries, query: "work res").map(\.id) == ["2"])
        #expect(FuzzyMatcher.filter(entries, query: "xyz").isEmpty)
        #expect(FuzzyMatcher.score("cafe", in: "café") != nil)
        #expect(FuzzyMatcher.filter(entries, query: "", limit: 1).count == 1)
    }
    @Test func homePrefixAndSeparateFieldsDoNotProduceFalseMatches() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entry = Candidate(id: "one", kind: .directory, title: "api", path: home + "/work/api")
        #expect(!entry.searchText.contains(home))
        #expect(FuzzyMatcher.filter([entry], query: "Users").isEmpty)
        let separate = Candidate(id: "two", kind: .session, title: "xy", path: "/abc/z", sessionID: "s")
        #expect(FuzzyMatcher.filter([separate], query: "xyz").isEmpty)
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
        "semantic":{"accentSolid":"#e05d3a","selection":"#e05d3a","surfaceRaised":"#262626"}}]
        """.utf8)
        let theme = RexTheme.resolve(preferences: ["Workspace.darkThemeID": "native"], builtins: data, systemIsDark: true)
        #expect(theme.accent.hex == "#e05d3a")
        #expect(theme.selection.hex == "#e05d3a")
        #expect(theme.panelBackground.hex == "#262626")
    }
}

private final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    var sessions: [(id: String, label: String, path: String)] = []
    var creations = 0
    var selections: [String] = []
    var rejectSelection = false
    var calls: [(String, [String])] = []
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
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
            let path = (block["options"] as! [String: Any])["cwd"] as! String
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
        if let index = arguments.firstIndex(of: "inspect"), index + 1 < arguments.count {
            return try json(["windows": [["layers": [["blocks": [["block_id": arguments[index + 1]]]]]]]])
        }
        if arguments.contains("process"), let index = arguments.firstIndex(of: "-s") {
            let session = sessions.first { $0.id == arguments[index + 1] }!
            return try json(["foreground": ["cwd": session.path]])
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
    @Test func aTabsDirectoryDoesNotIdentifyAnUnregisteredSession() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        let folder = try temporary.folder("project")
        runner.sessions = [("session:existing", "project", folder)]
        #expect(try await service(runner, temporary).connect(path: folder) != "session:existing")
        #expect(runner.creations == 1)
        #expect(!runner.calls.contains { $0.1.contains("inspect") || $0.1.contains("process") })
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
    @Test func folderDeduplicationAndAllScope() throws {
        let temporary = try TemporaryDirectory()
        let folder = try temporary.folder("project")
        let directories = PathIdentity.directories([folder, folder + "/.", "/not/a/real/resh/folder"])
        #expect(directories.count == 1)
        let session = Candidate(id: "s1", kind: .session, title: "project", path: folder, sessionID: "s1")
        #expect(Catalog(sessions: [session], directories: directories).entries(for: .all).count == 1)
    }
    @Test func listingOneHundredSessionsUsesOneRequestAndNoTabInspection() async throws {
        let temporary = try TemporaryDirectory(), runner = FakeRunner()
        runner.sessions = (0..<100).map { ("session:\($0)", "session-\($0)", "/irrelevant/tab/path") }
        let sessions = try await service(runner, temporary).sessionCandidates()
        #expect(sessions.count == 100)
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.1.contains("ls") == true)
        #expect(sessions.allSatisfy { $0.path == nil && $0.subtitle.isEmpty })
    }
    @Test func liveSnapshotMappingPerformsNoIO() {
        let sessions = [RexSession(sessionID: "session:live", label: "live")]
        let rows = ReshService.candidates(from: sessions)
        #expect(rows.map(\.title) == ["live"])
        #expect(rows[0].path == nil)
        #expect(ReshService.candidates(from: []).isEmpty)
    }
}

@Suite("Compact layout and layout-independent keyboard")
struct PanelTests {
    @Test func physicalLauncherIsScopedToRexNotTheInputLanguage() {
        #expect(PanelShortcut.launcherKeyCode == 1)
        #expect(PanelShortcut.launcherIsEnabled(frontmostBundleID: "com.superlogical.rex"))
        for app in [nil, "com.mitchellh.ghostty", "com.apple.TextEdit", "com.apple.finder"] {
            #expect(!PanelShortcut.launcherIsEnabled(frontmostBundleID: app))
        }
    }
    @Test func commandSourcesUsePhysicalNumberKeys() {
        #expect(PanelShortcut.action(keyCode: 18, command: true) == .scope(.sessions))
        #expect(PanelShortcut.action(keyCode: 19, command: true) == .scope(.all))
        #expect(PanelShortcut.action(keyCode: 20, command: true) == .scope(.directories))
        #expect(PanelShortcut.action(keyCode: 21, command: true) == .scope(.find))
        #expect(PanelShortcut.action(keyCode: 1, command: true) == .ignore)
        #expect(PanelShortcut.action(keyCode: 51, command: true, shift: true) == .delete)
        #expect(PanelShortcut.action(keyCode: 18, command: true, option: true) == nil)
    }
    @Test func nativeTextEditingIsNotStolen() {
        for key: UInt16 in [0, 8, 9, 7, 6, 51] { // A, C, V, X, Z, Backspace
            #expect(PanelShortcut.action(keyCode: key, command: true) == nil)
        }
        #expect(PanelShortcut.action(keyCode: 0, control: true) == nil)
        #expect(PanelShortcut.action(keyCode: 48, shift: true) == .move(-1))
        #expect(PanelShortcut.action(keyCode: 53) == .dismiss)
    }
    @Test func sessionRowsNeverDisplayOrSearchTabPaths() {
        let session = Candidate(id: "s", kind: .session, title: "session-name", path: "/wrong/tab/folder", sessionID: "s")
        #expect(session.displayTitle == "session-name")
        #expect(session.subtitle.isEmpty)
        #expect(session.searchText == "session-name")
    }
    @Test func heightTracksResultsWithoutAnOversizedEmptyPanel() {
        #expect(PanelLayout.width == 560)
        #expect(PanelLayout.rowHeight == 26)
        #expect(PanelLayout.height(resultCount: 5) == 216)
        #expect(PanelLayout.height(resultCount: 0) == 112)
        #expect(PanelLayout.height(resultCount: 100) == 398)
        #expect(PanelLayout.height(resultCount: 5, hasError: true) == 260)
    }
    @Test func bottomPaddingMatchesTopPaddingForEveryResultCount() {
        for count in [0, 1, 5, 12, 100] {
            #expect(PanelLayout.height(resultCount: count) - PanelLayout.listTop
                - PanelLayout.listHeight(resultCount: count) == PanelLayout.outerPadding)
        }
    }
    @Test func sectionsHaveTheSameBreathingRoomAsOuterEdges() {
        #expect(PanelLayout.sourcesTop - PanelLayout.outerPadding - PanelLayout.searchHeight == 8)
        #expect(PanelLayout.listTop - PanelLayout.sourcesTop - PanelLayout.sourcesHeight == 8)
    }
}

@Suite("Subprocess isolation")
struct RunnerTests {
    @Test func drainsBothPipes() throws {
        let result = try SystemCommandRunner().run("/usr/bin/python3",
            ["-c", "import sys; sys.stdout.write('o'*200000); sys.stderr.write('e'*200000)"], timeout: 10)
        #expect(result.status == 0 && result.stdout.count == 200_000 && result.stderr.count == 200_000)
    }
    @Test func timesOut() throws {
        let start = Date()
        let result = try SystemCommandRunner().run("/bin/sleep", ["5"], timeout: 0.1)
        #expect(result.status != 0)
        #expect(Date().timeIntervalSince(start) < 3)
    }
    @Test func doesNotInheritRexContext() throws {
        let result = try SystemCommandRunner().run("/usr/bin/env", [], timeout: 3)
        for key in ["TMUX", "REX_SERVER", "REX_SESSION", "REX_BLOCK", "REX_CLIENT"] {
            #expect(!result.text.split(separator: "\n").contains(where: { $0.hasPrefix(key + "=") }))
        }
    }
}
