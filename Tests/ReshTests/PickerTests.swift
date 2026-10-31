import AppKit
import Foundation
import ReshCore
import Testing
@testable import Resh

private final class CommandStub: CommandRunning, @unchecked Sendable {
    let directory: URL
    let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
    private let lock = NSLock()
    private let reply: ([String]) throws -> [String: Any]

    init(_ reply: @escaping ([String]) throws -> [String: Any]) throws {
        self.reply = reply
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("resh-picker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, directory: String?) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        return CommandResult(stdout: try JSONSerialization.data(withJSONObject: reply(arguments)))
    }
}

extension PickerTests {
    @Test @MainActor func numberedShortcutsSkipTheCurrentSession() async throws {
        var selected: String?
        let stub = try CommandStub { arguments in
            if arguments.contains("client") {
                return ["clients": [["client_id": "client:test", "info": ["kind": "app", "platform": "macos"]]]]
            }
            if arguments.contains("session.select") {
                let index = try #require(arguments.firstIndex(of: "--args"))
                let value = try JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: String]
                selected = value?["session_id"]
                return [:]
            }
            throw ReshError("Unexpected command: \(arguments)")
        }
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test"), runner: stub),
            registry: SessionRegistry(directory: stub.directory))
        let model = SearchModel(service: service, tools: stub.tools, readTheme: { _, _ in .fixture })
        defer { model.clear() }
        let sessions = ["a", "b", "c"].map { RexSession(sessionID: $0, label: $0) }
        model.prepare(service: service, sessions: sessions)
        model.query = "missing"
        #expect(model.results.isEmpty)
        model.openResult(1)
        #expect(!model.isConnecting)
        model.prepare(service: service, sessions: sessions, currentSessionID: "b")
        model.selection = try #require(model.results.firstIndex { $0.id == "c" })
        model.togglePin()
        model.query = "missing"
        #expect(model.results.isEmpty)
        model.openResult(1)
        #expect(!model.isConnecting)
        model.query = ""
        #expect(model.results.map(\.id) == ["c", "b", "a"])
        var connected = false
        model.onDismiss = { _ in connected = true }
        model.openResult(2)
        for _ in 0..<300 where !connected { try await Task.sleep(for: .milliseconds(10)) }
        #expect(connected)
        #expect(model.catalog.recentSessionIDs["client:test"] == ["a", "b"])
        #expect(selected == "a")
    }

    @Test(arguments: ["local", "remote", "none"], [false, true])
    @MainActor func createsNamedSessions(activeHost: String, selectionRefused: Bool) async throws {
        var creations = 0, refuse = selectionRefused
        var selected: String?
        let stub = try CommandStub { arguments in
            let index = try #require(arguments.firstIndex(of: "--server"))
            let server = arguments[index + 1]
            if arguments.contains("client") {
                #expect(server == "home")
                return ["clients": [["client_id": "client:test", "info": ["kind": "app", "platform": "macos"]]]]
            }
            if arguments.contains("hosts") {
                return ["hosts": [["host": ["id": "host:build", "label": "build", "endpoints": ["https://build.example"]]]]]
            }
            if arguments.contains("actions") { return ["actions": []] }
            if arguments.contains("ls") {
                var sessions = [["session_id": server == "home" ? "local" : "remote", "label": "Work"]]
                if server == (activeHost == "remote" ? "build" : "home") {
                    sessions.append(["session_id": "new", "label": "Scratch"])
                }
                return ["sessions": sessions]
            }
            if arguments.contains("session.create") {
                #expect(server == (activeHost == "remote" ? "build" : "home"))
                let value = try #require(try JSONSerialization.jsonObject(with: Data(arguments.last!.utf8)) as? [String: Any])
                let windows = try #require(value["initial_windows"] as? [[String: Any]])
                let block = try #require((windows.first?["layout"] as? [String: Any])?["block"] as? [String: Any])
                #expect(value["label"] as? String == "Scratch 'notes'")
                #expect(block["flavor"] as? String == "com.superlogical.terminal.shell")
                #expect((block["options"] as? [String: Any])?.isEmpty == true)
                creations += 1
                return ["session_id": "new"]
            }
            if arguments.contains("session.select") {
                #expect(server == "home")
                if refuse {
                    refuse = false
                    throw ReshError("Remote Control disabled", userMessage: "Enable Remote Control")
                }
                let index = try #require(arguments.firstIndex(of: "--args"))
                let value = try JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: String]
                selected = value?["session_id"]
                return [:]
            }
            throw ReshError("Unexpected command: \(arguments)")
        }
        let config = stub.directory.appendingPathComponent("config.toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test", server: "home"), runner: stub),
            registry: SessionRegistry(directory: stub.directory))
        let sessions = [RexSession(sessionID: "local", label: "Work")]
        var focus: String?
        let model = SearchModel(service: service, tools: stub.tools, sessions: sessions, configurationURL: config,
            readTheme: { _, _ in .fixture }, readFocusedSession: { _ in focus })
        defer { model.clear() }
        model.loadInitial()
        await model.loadingTask?.value
        await model.hostsTask?.value
        let host = try #require(model.hosts.first)
        model.receive(.success(.sessions([RexSession(sessionID: "remote", label: "Build")])), host: host)
        for _ in 0..<300 where model.isRemoteLoading { try await Task.sleep(for: .milliseconds(10)) }
        model.prepare(service: service, sessions: sessions, rexAppPID: 42, currentSessionID: activeHost == "none" ? nil : activeHost)
        let expectedHost = activeHost == "remote" ? host : nil
        #expect(model.newSessionHost == expectedHost)
        if activeHost != "none" { #expect(model.selected?.host != expectedHost) }
        model.query = "  Scratch 'notes'  "
        #expect(model.offersNewSession)
        var connected = false
        model.onDismiss = { _ in connected = true }
        if selectionRefused { model.createSession() }
        else { model.openSelection() }
        for _ in 0..<300 where model.isConnecting && !connected { try await Task.sleep(for: .milliseconds(10)) }
        if selectionRefused {
            #expect(!connected && model.error?.contains("Remote Control") == true)
            model.createSession()
            for _ in 0..<300 where !connected { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(connected)
        let expectedHistory = [Candidate.identity("new", host: expectedHost)]
            + (activeHost == "none" ? [] : [Candidate.identity(activeHost, host: expectedHost)])
        #expect(model.catalog.recentSessionIDs["client:test"] == expectedHistory)
        #expect(selected == "new")
        #expect(creations == 1)
        if activeHost != "none" {
            let created = Candidate(id: Candidate.identity("new", host: expectedHost), kind: .session,
                title: "Scratch", sessionID: "new", host: expectedHost)
            #expect(try await service.connectLast(from: created) == activeHost)
            focus = "new"
            let previous = expectedHost == nil ? sessions : [RexSession(sessionID: "remote", label: "Build")]
            model.receive(.success(.sessions(previous + [RexSession(sessionID: "new", label: "Scratch")])), host: expectedHost)
            await model.catalog.refreshHistory().value
            #expect(try await service.recentSessionIDs() == Array(expectedHistory.reversed()))
        }
    }

    @Test @MainActor func creationWaitsForTheActiveHost() async throws {
        let stub = try CommandStub { arguments in
            if arguments.contains("hosts") {
                return ["hosts": [["host": ["id": "host:build", "label": "build", "endpoints": ["https://build.example"]]]]]
            }
            if arguments.contains("actions") { return ["actions": []] }
            throw ReshError("Unexpected command: \(arguments)")
        }
        let config = stub.directory.appendingPathComponent("config.toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test"), runner: stub))
        var focus = "local"
        let model = SearchModel(service: service, tools: stub.tools, configurationURL: config,
            readTheme: { _, _ in .fixture }, readFocusedSession: { _ in focus })
        defer { model.clear() }
        model.prepare(service: service, sessions: [RexSession(sessionID: "local", label: "Work")],
            rexAppPID: 42, currentSessionID: focus)
        model.query = "Scratch"
        #expect(model.canCreateSession && model.offersNewSession)
        focus = "remote"
        model.refreshFocus()
        #expect(!model.canCreateSession && !model.offersNewSession)
        model.createSession()
        #expect(!model.isConnecting)
        model.loadInitial()
        await model.loadingTask?.value
        await model.hostsTask?.value
        let host = try #require(model.hosts.first)
        model.receive(.success(.sessions([RexSession(sessionID: "remote", label: "Build")])), host: host)
        for _ in 0..<300 where model.isRemoteLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.canCreateSession && model.offersNewSession && model.newSessionHost == host)
        focus = "local"
        model.refreshFocus()
        #expect(model.canCreateSession && model.offersNewSession && model.newSessionHost == nil)
    }

    @Test(arguments: ["ready", "loading", "error"])
    @MainActor func launcherTogglesPanel(_ state: String) {
        _ = NSApplication.shared
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget(clientID: "client:test")))
        let controller = PanelController(service: service, tools: tools, readTheme: { _, _ in .fixture })
        defer { controller.dismiss(focusRex: false); controller.model.clear() }
        func present() -> Bool {
            if state == "error" {
                controller.present(error: ReshError("Cannot connect"), retry: {})
            } else {
                controller.presentLoading()
                if state == "ready" {
                    controller.prepare(service: service, snapshot: RexSnapshot(client: "client:test", rexAppPID: 1,
                        sessions: [RexSession(sessionID: "s", label: "Session")]))
                }
            }
            return true
        }
        #expect(controller.toggle(open: present))
        #expect(controller.panel.isVisible)
        controller.model.query = "session"
        #expect(controller.toggle(open: present))
        #expect(!controller.panel.isVisible && !controller.model.isOpening && controller.model.query.isEmpty)
        #expect(controller.toggle(open: present))
        #expect(controller.panel.isVisible)
    }

    @Test @MainActor func pickerKeymapUpdatesKeepSearchAndSelection() throws {
        _ = NSApplication.shared
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget(clientID: "client:test")))
        let controller = PanelController(service: service, tools: tools, readTheme: { _, _ in .fixture })
        defer { controller.model.clear() }
        controller.prepare(service: service, snapshot: RexSnapshot(client: "client:test", rexAppPID: 1,
            sessions: [RexSession(sessionID: "a", label: "Session A"), RexSession(sessionID: "b", label: "Session B")]))
        controller.model.query = "session"
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        for (action, expectedSelection) in [("resh_next", 1), ("resh_previous", 0)] {
            let json = """
            {"bindings":[{"keys":["ctrl+[KeyJ]"],"mode":"resh","action":"\(action)"}],
             "modes":[{"name":"resh","exclusive":false}]}
            """
            let map = Keymap(try JSONDecoder().decode(RexKeymap.self, from: Data(json.utf8)))
            let selection = controller.model.selection
            controller.model.receive(.success(.keymap(map)))
            #expect(controller.model.selection == selection && controller.model.query == "session")
            #expect(controller.handle(event))
            #expect(controller.model.selection == expectedSelection)
        }
    }

    @Test(arguments: [false, true])
    @MainActor func rexActionsUseCallingContext(_ refused: Bool) async throws {
        _ = NSApplication.shared
        var calls = 0
        let stub = try CommandStub { arguments in
            #expect(arguments.contains("dev_layout"))
            for (flag, value) in [("-C", "client:test"), ("-s", "a"), ("--server", "home")] {
                let index = try #require(arguments.firstIndex(of: flag))
                #expect(arguments[index + 1] == value)
            }
            let index = try #require(arguments.firstIndex(of: "--args"))
            let args = try JSONDecoder().decode([String: KeyArgument].self, from: Data(arguments[index + 1].utf8))
            #expect(args["layout"] == .object(["paths": .array([.string("src"), .null]),
                "scale": .number(0.5), "count": .integer(2), "focus": .boolean(true)]))
            calls += 1
            if refused { throw ReshError("Action refused") }
            return [:]
        }
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test", server: "home"), runner: stub))
        let controller = PanelController(service: service, tools: stub.tools, readTheme: { _, _ in .fixture })
        defer { controller.model.clear() }
        controller.prepare(service: service, snapshot: RexSnapshot(client: "client:test", rexAppPID: 1,
            sessions: [RexSession(sessionID: "a", label: "Current"), RexSession(sessionID: "b", label: "Other")]), currentSessionID: "a")
        let json = """
        {"bindings":[{"keys":["ctrl+j"],"mode":"resh","action":"dev_layout",
          "args":{"layout":{"paths":["src",null],"scale":0.5,"count":2,"focus":true}}}],
         "modes":[{"name":"resh","exclusive":false}]}
        """
        controller.model.receive(.success(.keymap(Keymap(try JSONDecoder().decode(RexKeymap.self, from: Data(json.utf8))))))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        #expect(controller.handle(event))
        await controller.model.actionTask?.value
        #expect(calls == 1 && controller.model.selected?.id == "b" && controller.model.sessionCount == 2)
        #expect((controller.model.error != nil) == refused)
    }

    @Test(arguments: [false, true])
    @MainActor func launcherCommandsUseResidentState(_ cached: Bool) async throws {
        var created = false
        var createdPath: String?
        let stub = try CommandStub { arguments in
            if arguments.contains("client") {
                return ["clients": [["client_id": "client:test", "info": ["kind": "app", "platform": "macos"]]]]
            }
            if arguments.contains("ls") {
                var sessions = [["session_id": "a", "label": "First"]]
                if created { sessions.append(["session_id": "b", "label": "Project"]) }
                return ["sessions": sessions]
            }
            if arguments.contains("session.create") {
                let value = try #require(try JSONSerialization.jsonObject(with: Data(arguments.last!.utf8)) as? [String: Any])
                let windows = try #require(value["initial_windows"] as? [[String: Any]])
                let block = try #require((windows.first?["layout"] as? [String: Any])?["block"] as? [String: Any])
                let options = try #require(block["options"] as? [String: Any])
                #expect(value["label"] as? String == "Project")
                #expect(options["initial_input"] as? String == "true\n")
                createdPath = options["cwd"] as? String
                created = true
                return ["session_id": "b"]
            }
            if arguments.contains("session.select") { return [:] }
            throw ReshError("Unexpected command: \(arguments)")
        }
        let folder = stub.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = stub.directory.appendingPathComponent("config.toml")
        try """
        [[session]]
        name = "Project"
        path = "project"
        startup_command = "true"
        """.write(to: config, atomically: true, encoding: .utf8)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test"), runner: stub),
            registry: SessionRegistry(directory: stub.directory))
        let commands = LauncherCommands(service: service, configuration: try ConfigurationFile.load(config),
            sessions: cached ? ReshService.candidates(from: [RexSession(sessionID: "a", label: "First")]) : [])
        try "".write(to: config, atomically: true, encoding: .utf8)
        var last = LauncherRequest(operation: "last", client: "client:test", currentSessionID: "a")
        #expect(try await commands.run(last).isEmpty)
        let connected = try await commands.run(LauncherRequest(operation: "connect", client: "client:test", currentSessionID: "a", path: ".", cwd: folder.path))
        #expect(connected["session_id"] as? String == "b")
        #expect(connected["path"] as? String == folder.resolvingSymlinksInPath().path)
        #expect(createdPath == folder.resolvingSymlinksInPath().path)
        #expect(try await service.recentSessionIDs() == ["b", "a"])
        last.currentSessionID = "b"
        #expect(try await commands.run(last)["session_id"] as? String == "a")
        #expect(try await service.recentSessionIDs() == ["a", "b"])
        last.currentSessionID = "a"
        #expect(try await commands.run(last)["session_id"] as? String == "b")
        #expect(try await service.recentSessionIDs() == ["b", "a"])
        await #expect(throws: ReshError.self) {
            try await commands.run(LauncherRequest(operation: "connect", client: "client:test", path: "missing", cwd: folder.path))
        }
        #expect(try await service.recentSessionIDs() == ["b", "a"])
    }

    @Test @MainActor func liveUpdatesPreserveSearchAndSelection() async {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()))
        let sessions = [RexSession(sessionID: "first", label: "Session one"), RexSession(sessionID: "second", label: "Session two")]
        let model = SearchModel(service: service, tools: tools, sessions: sessions,
            readTheme: { _, _ in .fixture }, readPreferences: { ["Workspace.programActivitySeen": [:]] })
        model.query = "session"; model.selection = 1
        let results = model.results
        let record = RexAttentionRecord(sessionID: "first", blockID: "synthetic", state: "done", updatedAt: "2026-10-22T17:59:59Z")
        model.updateAttention([record])
        await model.attentionTask?.value
        #expect(model.attentionSessionIDs == ["first"])
        #expect(model.results == results && model.query == "session" && model.selection == 1)
        model.receive(.success(.sessions([
            RexSession(sessionID: "new", label: "Session new"), sessions[0],
            RexSession(sessionID: "second", label: "Session renamed"),
        ])))
        #expect(model.sessionCount == 3 && model.results.count == 3)
        #expect(model.selected?.id == "second" && model.selected?.title == "Session renamed")
        #expect(model.query == "session")
        model.receive(.success(.sessions([])))
        #expect(model.results.isEmpty && model.sessionCount == 0 && model.selection == 0)
        model.updateAttention([record])
        let pending = model.attentionTask
        model.clear()
        await pending?.value
        #expect(model.attentionSessionIDs.isEmpty)
        model.prepare(service: service, sessions: sessions)
        #expect(model.attentionSessionIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    @MainActor func focusChangesKeepHistoryBetweenPresentations(_ presented: Bool) async throws {
        let stub = try CommandStub { arguments in
            if arguments.contains("hosts") { return ["hosts": []] }
            if arguments.contains("kill") { return [:] }
            throw ReshError("Unexpected command: \(arguments)")
        }
        let config = stub.directory.appendingPathComponent("config.toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test"), runner: stub),
            registry: SessionRegistry(directory: stub.directory))
        let selectedService = service.at(RexTarget(clientID: "client:test"))
        var focus = "s"
        let model = SearchModel(service: service, tools: stub.tools, configurationURL: config,
            readTheme: { _, _ in .fixture }, readFocusedSession: { _ in focus })
        defer { model.clear() }
        model.loadInitial()
        await model.loadingTask?.value
        await model.hostsTask?.value
        model.prepare(service: selectedService, sessions: [RexSession(sessionID: "s", label: "First")],
            rexAppPID: 42, currentSessionID: focus)
        for _ in 0..<300 {
            if model.results.first?.title == "First", model.catalog.recentSessionIDs["client:test"] == ["s"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.results.map(\.title) == ["First"])
        model.query = "first"
        model.endPresentation()
        #expect(model.query.isEmpty && model.results.map(\.title) == ["First"])
        let sessions = [RexSession(sessionID: "s", label: "Renamed"), RexSession(sessionID: "new", label: "New")]
        model.receive(.success(.sessions(sessions)))
        #expect(model.results.map(\.title) == ["Renamed", "New"])
        #expect(try await selectedService.recentSessionIDs() == ["s"])
        focus = "new"
        if presented { model.prepare(service: selectedService, sessions: sessions, rexAppPID: 42, currentSessionID: focus) }
        else { model.refreshFocus() }
        for _ in 0..<300 where model.catalog.recentSessionIDs["client:test"] != ["new", "s"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.catalog.recentSessionIDs["client:test"] == ["new", "s"])
        if presented {
            #expect(model.results.map(\.title) == ["New", "Renamed"])
            #expect(model.numberedRows.map { model.results[$0].id } == ["s"])
        }
        for sessionID in ["s", "new"] {
            focus = sessionID
            model.refreshFocus()
            let recent = sessionID == "s" ? ["s", "new"] : ["new", "s"]
            for _ in 0..<300 where model.catalog.recentSessionIDs["client:test"] != recent {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.catalog.recentSessionIDs["client:test"] == recent)
        }
        #expect(!model.isLoading)
        if presented { model.selection = 0; model.deleteSelection() }
        else {
            model.receive(.success(.sessions([sessions[0]])))
        }
        for _ in 0..<300 where model.isConnecting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.results.map(\.id) == ["s"] && model.currentCandidateID == nil)
        focus = "s"
        model.refreshFocus()
        for _ in 0..<300 {
            if !model.isConnecting, model.catalog.recentSessionIDs["client:test"] == ["s"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.results.map(\.id) == ["s"] && !model.isConnecting)
        if presented { #expect(model.currentCandidateID == "s" && model.numberedRows.isEmpty) }
        #expect(try await selectedService.recentSessionIDs() == ["s"])
    }

    @Test(arguments: [false, true])
    @MainActor func retryAfterFailedSelection(_ currentMissing: Bool) async throws {
        let stub = try CommandStub { arguments in
            if arguments.contains("hosts") { return ["hosts": []] }
            if arguments.contains("client") {
                return ["clients": [["client_id": "client:test", "info": ["kind": "app", "platform": "macos"]]]]
            }
            if arguments.contains("ls") { return ["sessions": [["session_id": "current", "label": "Current"]]] }
            if arguments.contains("session.select") {
                throw ReshError("Remote Control disabled", userMessage: "Enable Remote Control")
            }
            throw ReshError("Unexpected command: \(arguments)")
        }
        let provider = SnapshotStub([
            .success(RexSnapshot(client: "client:test", rexAppPID: 1, sessions: [RexSession(sessionID: "new", label: "Fresh session")])),
        ])
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test"), runner: stub),
            registry: SessionRegistry(directory: stub.directory))
        let config = stub.directory.appendingPathComponent("config.toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let model = SearchModel(service: service, tools: stub.tools,
            sessions: [RexSession(sessionID: "old", label: "Session")],
            configurationURL: config, snapshotProvider: provider, readTheme: { _, _ in .fixture })
        defer { model.clear() }
        model.loadInitial()
        await model.loadingTask?.value
        if currentMissing {
            model.prepare(service: service, sessions: [RexSession(sessionID: "old", label: "Session")], currentSessionID: "current")
        }
        model.query = "session"
        model.openSelection()
        for _ in 0..<300 where model.isConnecting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.error != nil && model.canRetry)
        model.retry()
        await model.loadingTask?.value
        #expect(model.error == nil && model.query == "session")
        #expect(model.results.map(\.title) == ["Fresh session"])
    }

    @Test @MainActor func hostUpdatesPreserveSelection() async throws {
        let stub = try CommandStub { arguments in
            if arguments.contains("hosts") {
                return ["hosts": [["host": ["id": "host:build", "label": "build", "endpoints": ["https://build.example"]]]]]
            }
            if arguments.contains("actions") { return ["actions": []] }
            throw ReshError("Unexpected command: \(arguments)")
        }
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(), runner: stub))
        let local = RexSession(sessionID: "local", label: "api")
        let config = stub.directory.appendingPathComponent("config.toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let model = SearchModel(service: service, tools: stub.tools, sessions: [local],
            recentSessionIDs: ["host:build/remote", "local"], configurationURL: config,
            readTheme: { _, _ in .fixture }, readPreferences: { ["Workspace.programActivitySeen": [:]] })
        defer { model.clear() }
        model.loadInitial()
        await model.loadingTask?.value
        await model.hostsTask?.value
        let host = try #require(model.hosts.first)
        model.receive(.success(.sessions([RexSession(sessionID: "remote", label: "api")])), host: host)
        #expect(model.results.count == 2 && model.showsHosts)
        #expect(model.results.map(\.id) == ["host:build/remote", "local"])
        model.query = "api build"
        #expect(model.results.count == 1 && model.selected?.host == host && model.showsHosts)
        let selectedID = model.selected?.id
        model.receive(.success(.sessions([RexSession(sessionID: "another", label: "api"), local])))
        #expect(model.selected?.id == selectedID && model.query == "api build")
        model.receive(.success(.records([RexAttentionRecord(sessionID: "remote", blockID: "b", state: "done", updatedAt: "2026-10-23T12:00:00Z")])), host: host)
        await model.attentionTask?.value
        #expect(model.attentionSessionIDs == [Candidate.identity("remote", host: host)])
        model.receive(.success(.sessions([RexSession(sessionID: "new", label: "api")])), host: host)
        #expect(model.sessionCount == 3)
        for _ in 0..<200 where model.visibleSources.map(\.id) != [.sessions] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.visibleSources.map(\.id) == [.sessions])
    }

    @Test(arguments: ["none", "local", "remote", "projects", "custom"])
    @MainActor func sourceAvailability(_ scenario: String) async throws {
        var enabled = scenario == "remote"
        let stub = try CommandStub { arguments in
            if arguments.contains("hosts") {
                return ["hosts": ["first", "second"].map { ["host": ["id": $0, "label": $0, "endpoints": ["https://" + $0]]] }]
            }
            if arguments.contains("actions") {
                let index = try #require(arguments.firstIndex(of: "--server"))
                return ["actions": arguments[index + 1] == "first" ? [] : [
                    ["name": "resh_info", "kind": "lua"], ["name": "resh_query", "kind": "lua"],
                ]]
            }
            if arguments.contains("resh_info") { return ["version": 1, "functions": enabled ? ["resolve", "zoxide"] : []] }
            return [:]
        }
        let config = stub.directory.appendingPathComponent("config.toml")
        let text = scenario == "projects" ? "[[session]]\nname = 'Project'\npath = '.'\n"
            : scenario == "custom" ? "source_order = ['Find']\ninitial_source = 'Find'\n" : ""
        try text.write(to: config, atomically: true, encoding: .utf8)
        let tools = Tools(rex: stub.tools.rex, zoxide: nil, fd: scenario == "local" ? "/usr/bin/true" : nil, rexApp: stub.tools.rexApp)
        let model = SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget(), runner: stub)),
            tools: tools, configurationURL: config, readTheme: { _, _ in .fixture })
        defer { model.clear() }
        let expected: [SearchScope]
        switch scenario {
        case "local": expected = [.sessions, .find]
        case "remote": expected = [.sessions, .all, .directories]
        case "projects": expected = [.sessions, .all, .configs]
        default: expected = [.sessions]
        }
        func waitForSources(_ sources: [SearchScope]) async throws {
            for _ in 0..<200 {
                if model.visibleSources.map(\.id) == sources { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Source availability did not update")
        }
        model.loadInitial()
        await model.loadingTask?.value
        await model.hostsTask?.value
        try await waitForSources(expected)
        for host in model.hosts { model.receive(.success(.sessions([])), host: host) }
        for source in Array(expected.dropFirst()) + [.sessions] {
            model.cycleSource(1)
            #expect(model.scope == source)
            await model.loadingTask?.value
        }
        for source in Array(expected.dropFirst().reversed()) + [.sessions] {
            model.cycleSource(-1)
            #expect(model.scope == source)
            await model.loadingTask?.value
        }
        if scenario == "remote" {
            model.changeScope(.directories)
            await model.loadingTask?.value
            for _ in 0..<200 where model.isRemoteLoading { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.results.isEmpty && model.visibleSources.map(\.id) == expected)
            enabled = false
            let host = try #require(model.hosts.first { $0.label == "second" })
            model.receive(.success(.capabilitiesChanged), host: host)
            try await waitForSources([.sessions])
            #expect(model.scope == .sessions)
            model.changeScope(.directories)
            model.cycleSource(1)
            #expect(model.scope == .sessions)
        }
    }
}
