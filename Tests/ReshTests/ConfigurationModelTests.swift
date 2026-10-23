import Foundation
import ReshCore
import Testing
@testable import Resh

@Suite("Live configuration and asynchronous sources")
struct ConfigurationModelTests {
    @Test @MainActor func reloadsSourcesKeysAndProjectsWithoutRestarting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let model = try SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget())),
            tools: tools, sessions: [RexSession(sessionID: "s", label: "Live session")], configurationURL: url,
            readTheme: { _, _ in .fixture })
        try """
        source_order = ["sessions", "configs"]
        [keymap]
        "ctrl+t" = "source:configs"
        [[session]]
        name = "Project one"
        path = "project"
        """.write(to: url, atomically: true, encoding: .utf8)
        model.loadInitial()
        await model.loadingTask?.value
        #expect(model.configuration.visibleSources.map(\.id) == [.sessions, .configs])
        #expect(model.configuration.keymap.action(for: try KeyChord("ctrl+t")) == .scope(.configs))
        model.changeScope(.configs)
        await model.loadingTask?.value
        #expect(model.results.map(\.title) == ["Project one"])
        model.query = "one"
        model.clear()
        #expect(model.results.isEmpty && model.query.isEmpty)
        try """
        initial_source = "configs"
        source_order = ["configs"]
        [[session]]
        name = "Project two"
        path = "project"
        """.write(to: url, atomically: true, encoding: .utf8)
        model.prepare(service: ReshService(client: RexClient(tools: tools, target: RexTarget())), sessions: [], configurationURL: url)
        model.loadInitial()
        await model.loadingTask?.value
        #expect(model.scope == .configs)
        #expect(model.results.map(\.title) == ["Project two"])
        #expect(model.error == nil)
        try "bad = [".write(to: url, atomically: true, encoding: .utf8)
        model.loadInitial()
        await model.loadingTask?.value
        #expect(model.results.isEmpty && !model.isConfigurationReady && !model.canRetry)
        #expect(model.error?.contains(url.path) == true)
        let other = root.appendingPathComponent("other.toml")
        model.prepare(service: ReshService(client: RexClient(tools: tools, target: RexTarget())),
            sessions: [], configurationURL: other)
        model.loadInitial()
        await model.loadingTask?.value
        #expect(model.results.isEmpty && !model.isConfigurationReady && !model.canRetry)
        #expect(model.error?.contains(other.path) == true)
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
        let model = try SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget())), tools: tools,
            sessions: [RexSession(sessionID: "s", label: "Live")], configurationURL: url, readTheme: { _, _ in .fixture })
        model.loadInitial()
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        #expect(model.scope == .all && model.isLoading)
        #expect(model.results.map(\.title) == ["Live", "Project"])
        let oldTask = model.loadingTask
        model.changeScope(.sessions)
        #expect(!model.isLoading && model.results.map(\.title) == ["Live"])
        let started = ProcessInfo.processInfo.systemUptime
        await oldTask?.value
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
        #expect(model.scope == .sessions && model.error == nil)
        model.clear()
    }
}
