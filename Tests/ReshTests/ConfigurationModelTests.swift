import Foundation
import ReshCore
import Testing
@testable import Resh

@Suite("Configuration and asynchronous sources")
struct ConfigurationModelTests {
    @Test @MainActor func configurationStaysFixedUntilRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()))
        let sessions = [RexSession(sessionID: "s", label: "Live session")]
        try """
        source_order = ["sessions", "configs"]
        [keymap]
        "ctrl+t" = "source:configs"
        [[session]]
        name = "Project one"
        path = "project"
        """.write(to: url, atomically: true, encoding: .utf8)
        let model = SearchModel(service: service, tools: tools, sessions: sessions, configurationURL: url,
            readTheme: { _, _ in .fixture })
        defer { model.clear() }
        model.startBackground()
        await model.loadingTask?.value
        #expect(model.configuration.visibleSources.map(\.id) == [.sessions, .configs])
        #expect(model.configuration.keymap.action(for: try KeyChord("ctrl+t")) == .scope(.configs))
        model.changeScope(.configs)
        await model.loadingTask?.value
        #expect(model.results.map(\.title) == ["Project one"])
        model.query = "one"
        model.endPresentation()
        #expect(model.results.map(\.title) == ["Live session"] && model.query.isEmpty)
        try """
        initial_source = "configs"
        source_order = ["configs"]
        [keymap]
        "ctrl+w" = "source:configs"
        [[session]]
        name = "Project two"
        path = "project"
        """.write(to: url, atomically: true, encoding: .utf8)
        model.stopBackground()
        model.startBackground()
        await model.loadingTask?.value
        model.prepare(service: service, sessions: sessions)
        #expect(model.scope == .sessions)
        model.changeScope(.configs)
        model.retry()
        await model.loadingTask?.value
        #expect(model.configuration.visibleSources.map(\.id) == [.sessions, .configs])
        #expect(model.configuration.keymap.action(for: try KeyChord("ctrl+t")) == .scope(.configs))
        #expect(model.results.map(\.title) == ["Project one"])

        let restarted = SearchModel(service: service, tools: tools, sessions: sessions, configurationURL: url,
            readTheme: { _, _ in .fixture })
        defer { restarted.clear() }
        restarted.loadInitial()
        await restarted.loadingTask?.value
        #expect(restarted.scope == .configs)
        #expect(restarted.configuration.visibleSources.map(\.id) == [.configs])
        #expect(restarted.configuration.keymap.action(for: try KeyChord("ctrl+w")) == .scope(.configs))
        #expect(restarted.configuration.keymap.action(for: try KeyChord("ctrl+t")) == nil)
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
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()))
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
        initial_source = "all"
        [[session]]
        name = "Project"
        path = "project"
        [[sources]]
        id = "all"
        type = "union"
        sources = ["sessions", "configs", "slow"]
        [[sources]]
        id = "slow"
        type = "command"
        cwd = "."
        command = ["/bin/sh", "-c", "touch started; sleep 10"]
        timeout = 20
        """.write(to: url, atomically: true, encoding: .utf8)
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let model = SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget())), tools: tools,
            sessions: [RexSession(sessionID: "s", label: "Live")], configurationURL: url, readTheme: { _, _ in .fixture })
        model.loadInitial()
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
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
        let started = ProcessInfo.processInfo.systemUptime
        await oldTask?.value
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
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
        initial_source = "all"
        [[session]]
        name = "Test project"
        path = "project"
        [[sources]]
        id = "all"
        type = "union"
        sources = ["configs", "nested"]
        [[sources]]
        id = "nested"
        type = "union"
        sources = ["folders", "sessions", "configs"]
        [[sources]]
        id = "folders"
        type = "command"
        cwd = "."
        command = ["/bin/sh", "-c", "touch started; while [ ! -f ready ]; do sleep 0.01; done; cat folders.txt"]
        """.write(to: url, atomically: true, encoding: .utf8)
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let model = SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget())), tools: tools,
            sessions: [RexSession(sessionID: "s", label: "Test session")], configurationURL: url, readTheme: { _, _ in .fixture })
        defer { model.clear() }
        model.loadInitial()
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        model.receive(.success(.sessions([RexSession(sessionID: "s", label: "Test changed")])))
        try "".write(to: root.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
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
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()))
        let model = SearchModel(service: service, tools: tools,
            sessions: [RexSession(sessionID: "a", label: "Session"), RexSession(sessionID: "b", label: "Session"),
                       RexSession(sessionID: "c", label: "Other"), RexSession(sessionID: "d", label: "Session")],
            recentSessionIDs: ["b", "a"], readTheme: { _, _ in .fixture })
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

    @Test @MainActor func pinningKeepsSessionOrder() throws {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()))
        let sessions = ["a", "b", "c", "d"].map { RexSession(sessionID: $0, label: $0) }
        let model = SearchModel(service: service, tools: tools, readTheme: { _, _ in .fixture })
        defer { model.clear() }
        model.prepare(service: service, sessions: sessions, recentSessionIDs: ["b", "a"], currentSessionID: "b")
        model.selection = try #require(model.results.firstIndex { $0.id == "c" })
        model.togglePin()
        model.selection = try #require(model.results.firstIndex { $0.id == "a" })
        model.togglePin()
        #expect(model.results.map(\.id) == ["c", "a", "b", "d"])
        #expect(model.selected?.id == "a")
        model.endPresentation()
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
    }
}
