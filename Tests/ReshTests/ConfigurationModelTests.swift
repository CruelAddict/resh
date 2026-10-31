import Foundation
import ReshCore
import Testing
@testable import Resh

extension PickerTests {
    @Test(arguments: ["", "keyboard_layout_search = false", "keyboard_layout_search = true"], [false, true])
    @MainActor func keyboardLayoutSearchConfiguration(_ config: String, _ hasCurrentSession: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-layouts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try config.write(to: url, atomically: true, encoding: .utf8)
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()), stateURL: nil)
        let sessions = [RexSession(sessionID: "code", label: "code"), RexSession(sessionID: "native", label: "сщву")]
        let model = SearchModel(service: service, tools: tools, sessions: sessions, configurationURL: url,
            readTheme: { _, _ in .fixture }, readFocusedSession: { _ in nil }, readKeyboardLayouts: { .fixture })
        defer { model.clear() }
        model.prepare(service: service, sessions: sessions, currentSessionID: hasCurrentSession ? "native" : nil)
        let enabled = config != "keyboard_layout_search = false"
        #expect(model.configuration.keyboardLayoutSearch == enabled)
        model.query = "сщву"
        #expect(Set(model.results.map(\.id)) == (enabled ? ["code", "native"] : ["native"]))
        #expect(model.query == "сщву")
        model.query = "СЩВ"
        #expect(Set(model.results.map(\.id)) == (enabled ? ["code", "native"] : ["native"]))
    }

    @Test @MainActor func keyboardLayoutsRefreshBetweenPresentations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-layouts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try "keyboard_layout_search = true".write(to: url, atomically: true, encoding: .utf8)
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()), stateURL: nil)
        let sessions = [RexSession(sessionID: "code", label: "code")]
        var layouts = KeyboardLayouts.fixture
        let model = SearchModel(service: service, tools: tools, sessions: sessions, configurationURL: url,
            readTheme: { _, _ in .fixture }, readFocusedSession: { _ in nil }, readKeyboardLayouts: { layouts })
        defer { model.clear() }
        model.query = "сщву"
        #expect(model.results.map(\.id) == ["code"] && !model.offersNewSession)
        model.endPresentation()
        layouts = KeyboardLayouts([])
        model.prepare(service: service, sessions: sessions)
        model.query = "сщву"
        #expect(model.results.isEmpty && model.offersNewSession)
        model.query = "code"
        #expect(model.results.map(\.id) == ["code"])
    }

    @Test @MainActor func configurationStaysFixedUntilRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()), stateURL: nil)
        let sessions = [RexSession(sessionID: "s", label: "Live session")]
        try """
        source_order = ["Sessions", "Work projects"]
        [[sources]]
        name = "Work projects"
        type = "projects"
        [[session]]
        name = "Project one"
        path = "project"
        """.write(to: url, atomically: true, encoding: .utf8)
        let model = SearchModel(service: service, tools: tools, sessions: sessions, configurationURL: url,
            readTheme: { _, _ in .fixture })
        defer { model.clear() }
        model.startBackground()
        await model.loadingTask?.value
        let projects = SearchScope(rawValue: "Work projects")
        #expect(model.configuration.visibleSources.map(\.id) == [.sessions, projects])
        model.changeScope(projects)
        await model.loadingTask?.value
        #expect(model.results.map(\.title) == ["Project one"])
        model.query = "one"
        model.endPresentation()
        #expect(model.results.map(\.title) == ["Live session"] && model.query.isEmpty)
        try """
        initial_source = "Projects"
        source_order = ["Projects"]
        [[session]]
        name = "Project two"
        path = "project"
        """.write(to: url, atomically: true, encoding: .utf8)
        model.stopBackground()
        model.startBackground()
        await model.loadingTask?.value
        model.prepare(service: service, sessions: sessions)
        #expect(model.scope == .sessions)
        model.changeScope(projects)
        model.retry()
        await model.loadingTask?.value
        #expect(model.configuration.visibleSources.map(\.id) == [.sessions, projects])
        #expect(model.results.map(\.title) == ["Project one"])

        let restarted = SearchModel(service: service, tools: tools, sessions: sessions, configurationURL: url,
            readTheme: { _, _ in .fixture })
        defer { restarted.clear() }
        restarted.loadInitial()
        await restarted.loadingTask?.value
        #expect(restarted.scope == .configs)
        #expect(restarted.configuration.visibleSources.map(\.id) == [.configs])
        #expect(restarted.results.map(\.title) == ["Project two"])
    }

    @Test(arguments: ["missing", "invalid"])
    @MainActor func configurationErrorsRequireRestart(_ scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        if scenario == "invalid" { try "source_order = []".write(to: url, atomically: true, encoding: .utf8) }
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()), stateURL: nil)
        let model = SearchModel(service: service, tools: tools, configurationURL: url, readTheme: { _, _ in .fixture })
        defer { model.clear() }
        model.startBackground()
        #expect(model.error?.contains(url.path) == true)
        #expect(model.error?.contains("resh service restart") == true)
        #expect(!model.isConfigurationReady && !model.canRetry && !model.canCreateSession)
        let error = model.error

        try "".write(to: url, atomically: true, encoding: .utf8)
        model.retry()
        model.stopBackground()
        model.startBackground()
        await model.loadingTask?.value
        #expect(model.error == error && model.results.isEmpty && !model.isConfigurationReady)

        let restarted = SearchModel(service: service, tools: tools, configurationURL: url, readTheme: { _, _ in .fixture })
        defer { restarted.clear() }
        #expect(restarted.isConfigurationReady && restarted.error == nil)
    }

    @Test @MainActor func compositeSourcesKeepFreshSessionsAvailableWhileProvidersRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-slow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try """
        initial_source = "All"
        [[session]]
        name = "Project"
        path = "project"
        [[sources]]
        name = "All"
        type = "union"
        sources = ["Sessions", "Projects", "Slow"]
        [[sources]]
        name = "Slow"
        type = "command"
        cwd = "."
        command = ["/usr/bin/true"]
        """.write(to: url, atomically: true, encoding: .utf8)
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let runner = SourceCommandStub()
        let model = SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget()), stateURL: nil), tools: tools,
            sessions: [RexSession(sessionID: "s", label: "Live")], configurationURL: url, sourceRunner: runner,
            readTheme: { _, _ in .fixture })
        defer { runner.release(); model.clear() }
        model.loadInitial()
        try await runner.waitUntilStarted()
        #expect(model.scope == .all && model.isLoading)
        #expect(model.results.map(\.title) == ["Live", "Project"])
        model.receive(.success(.sessions([RexSession(sessionID: "new", label: "Fresh")])))
        #expect(model.results.map(\.title) == ["Fresh", "Project"] && model.isLoading)
        model.query = "missing"
        #expect(model.results.isEmpty && !model.offersNewSession)
        model.query = ""
        let oldTask = model.loadingTask
        model.changeScope(.sessions)
        #expect(!model.isLoading && model.results.map(\.title) == ["Fresh"])
        runner.release()
        await oldTask?.value
        #expect(model.scope == .sessions)
        model.clear()
    }
    @Test @MainActor func sessionChangesKeepFolderSnapshotsUntilSourceSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-snapshot-" + UUID().uuidString)
        for name in ["project", "test-folder-one", "test-folder-two"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml"), paths = root.appendingPathComponent("folders.txt")
        try "test-folder-one\n".write(to: paths, atomically: true, encoding: .utf8)
        try """
        initial_source = "All"
        [[session]]
        name = "Test project"
        path = "project"
        [[sources]]
        name = "All"
        type = "union"
        sources = ["Projects", "Nested"]
        [[sources]]
        name = "Nested"
        type = "union"
        sources = ["Folders", "Sessions", "Projects"]
        [[sources]]
        name = "Folders"
        type = "command"
        cwd = "."
        command = ["/bin/cat", "folders.txt"]
        """.write(to: url, atomically: true, encoding: .utf8)
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let runner = SourceCommandStub { CommandResult(stdout: try Data(contentsOf: paths)) }
        let model = SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget()), stateURL: nil), tools: tools,
            sessions: [RexSession(sessionID: "s", label: "Test session")], configurationURL: url, sourceRunner: runner,
            readTheme: { _, _ in .fixture })
        defer { runner.release(); model.clear() }
        model.loadInitial()
        try await runner.waitUntilStarted()
        model.receive(.success(.sessions([RexSession(sessionID: "s", label: "Test changed")])))
        runner.release()
        await model.loadingTask?.value
        #expect(model.results.map(\.title) == ["Test project", "test-folder-one", "Test changed"])
        model.query = "test"
        model.selection = try #require(model.results.firstIndex { $0.kind == .directory })
        let selectedID = model.selected?.id
        try "test-folder-two\n".write(to: paths, atomically: true, encoding: .utf8)
        model.receive(.success(.sessions([
            RexSession(sessionID: "s", label: "Test renamed"), RexSession(sessionID: "new", label: "Test new"),
        ])))
        #expect(model.sessionCount == 2 && model.results.count == 4)
        #expect(model.selected?.id == selectedID && model.query == "test")
        #expect(model.results.contains { $0.title == "test-folder-one" })
        #expect(!model.results.contains { $0.title == "test-folder-two" })
        model.query = ""
        model.receive(.success(.sessions([])))
        #expect(model.results.map(\.title) == ["Test project", "test-folder-one"])
        model.changeScope(.sessions)
        model.changeScope(.all)
        await model.loadingTask?.value
        #expect(model.results.map(\.title) == ["Test project", "test-folder-two"])
    }

    @Test @MainActor func recentSessionsKeepSearchRankingAndSelection() {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()), stateURL: nil)
        let model = SearchModel(service: service, tools: tools,
            sessions: [RexSession(sessionID: "a", label: "Session"), RexSession(sessionID: "b", label: "Session"),
                       RexSession(sessionID: "c", label: "Other"), RexSession(sessionID: "d", label: "Session")],
            recentSessionIDs: ["b", "a"], configurationURL: ConfigurationFile.emptyFixture, readTheme: { _, _ in .fixture })
        defer { model.clear() }
        #expect(model.results.map(\.id) == ["b", "a", "c", "d"])
        model.query = "session"
        #expect(model.results.map(\.id) == ["b", "a", "d"])
        model.selection = 1
        model.receive(.success(.sessions([
            RexSession(sessionID: "d", label: "Session"), RexSession(sessionID: "a", label: "Session"),
            RexSession(sessionID: "b", label: "Session"), RexSession(sessionID: "new", label: "Session"),
        ])))
        #expect(model.results.map(\.id) == ["b", "a", "d", "new"])
        #expect(model.selected?.id == "a")
        model.query = "other"
        model.receive(.success(.sessions([
            RexSession(sessionID: "a", label: "Other"), RexSession(sessionID: "b", label: "Session other"),
        ])))
        #expect(model.results.first?.id == "a")
        model.prepare(service: service, sessions: [RexSession(sessionID: "a", label: "A"), RexSession(sessionID: "b", label: "B")],
            recentSessionIDs: ["a", "b"])
        #expect(model.results.map(\.id) == ["a", "b"])
    }

    @Test @MainActor func pinnedSessionOrderSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let client = RexClient(tools: tools, target: RexTarget())
        let stateURL = root.appendingPathComponent("state.json")
        var service = ReshService(client: client, stateURL: stateURL)
        let sessions = ["a", "b", "c", "d"].map { RexSession(sessionID: $0, label: $0) }
        var model = SearchModel(service: service, tools: tools, configurationURL: ConfigurationFile.emptyFixture,
            readTheme: { _, _ in .fixture }, readFocusedSession: { _ in nil })
        defer { model.clear() }
        model.prepare(service: service, sessions: sessions, recentSessionIDs: ["b", "a"], currentSessionID: "b")
        model.selection = try #require(model.results.firstIndex { $0.id == "c" })
        model.togglePin()
        model.selection = try #require(model.results.firstIndex { $0.id == "a" })
        model.togglePin()
        #expect(model.results.map(\.id) == ["c", "a", "b", "d"])
        #expect(model.selected?.id == "a")
        model.clear()
        service = ReshService(client: client, stateURL: stateURL)
        model = SearchModel(service: service, tools: tools, configurationURL: ConfigurationFile.emptyFixture,
            readTheme: { _, _ in .fixture }, readFocusedSession: { _ in nil })
        #expect(model.pinnedSessionIDs == ["c", "a"])
        model.prepare(service: service, sessions: sessions, recentSessionIDs: ["d", "a", "c"], currentSessionID: "a")
        #expect(model.results.map(\.id) == ["c", "a", "d", "b"])
        #expect(!model.offersNewSession)
        model.query = "d"
        #expect(model.results.map(\.id) == ["d"])
        #expect(!model.offersNewSession)
        model.query = "missing"
        #expect(model.results.isEmpty && model.offersNewSession)
        model.query = "   "
        #expect(!model.offersNewSession)
        model.query = ""
        model.selection = try #require(model.results.firstIndex { $0.id == "a" })
        model.togglePin()
        #expect(model.results.map(\.id) == ["c", "a", "d", "b"])
        model.selection = 0
        model.togglePin()
        #expect(model.results.map(\.id) == ["a", "d", "c", "b"])
        #expect(ReshService(client: client, stateURL: stateURL).pinnedSessionIDs().isEmpty)
    }
}
