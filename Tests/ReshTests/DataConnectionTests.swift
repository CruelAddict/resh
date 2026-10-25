import AppKit
import Foundation
import CoreFoundation
import ReshCore
import Testing
@testable import Resh

private final class StubRex {
    let directory: URL
    let tools: Tools
    init(body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("resh-connection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("rex")
        try ("#!/usr/bin/python3\nimport json,sys,time\n" + body).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        tools = Tools(rex: executable.path, zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class AttentionUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [[RexAttentionRecord]] = []
    private var sessionUpdates: [[RexSession]] = []
    var values: [[RexAttentionRecord]] { lock.lock(); defer { lock.unlock() }; return updates }
    var sessions: [[RexSession]] { lock.lock(); defer { lock.unlock() }; return sessionUpdates }
    func append(_ result: Result<RexEventUpdate, Error>) {
        lock.lock(); defer { lock.unlock() }
        switch result {
        case let .success(.records(records)): updates.append(records)
        case let .success(.sessions(sessions)): sessionUpdates.append(sessions)
        case .success(.hostsChanged), .success(.capabilitiesChanged), .success(.clients), .success(.reconnecting),
             .success(.created), .success(.destroyed): break
        case .failure: updates.append([])
        }
    }
    func waitForCount(_ count: Int) async throws {
        for _ in 0..<300 {
            if values.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ReshError("Timed out waiting for attention updates")
    }
}

@Suite("Session data connections")
struct DataConnectionTests {
    /// Read-only compatibility check against a running local Rex app and server.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESH_REX_SMOKE"] == "1",
        "Set RESH_REX_SMOKE=1 to check a running Rex."))
    func rexCompatibility() async throws {
        let tools = try Tools.discover()
        defer {
            for child in RexProcess.stopAll(executable: tools.rex) {
                #expect(child.waitForExit(), "Rex smoke connection did not exit.")
            }
        }
        let client = RexClient(tools: tools,
            target: RexTarget(clientID: ProcessInfo.processInfo.environment["RESH_REX_SMOKE_CLIENT"]))
        _ = try client.sessions()
        let resolved = try client.resolveClient()
        let target = RexTarget(clientID: resolved.id)
        let data = RexDataConnection(tools: tools)
        defer { data.stop(); data.waitUntilStopped() }
        let snapshot = try data.snapshot(target: target)
        #expect(snapshot.client == resolved.id && snapshot.rexAppPID > 0)

        for kind in [RexEventConnection.Kind.catalog, .attention] {
            let connection = RexEventConnection(tools: tools, kind: kind)
            let (updates, continuation) = AsyncThrowingStream<RexEventUpdate, Error>.makeStream()
            defer {
                connection.stop()
                connection.waitUntilStopped()
                continuation.finish()
            }
            connection.start(target: target) { result in
                switch result {
                case let .success(update): continuation.yield(update)
                case let .failure(error): continuation.finish(throwing: error)
                }
            }
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask {
                    var needsClients = kind == .catalog, needsSessions = kind == .catalog
                    var needsRecords = kind == .attention
                    for try await update in updates {
                        switch update {
                        case .clients: needsClients = false
                        case .sessions: needsSessions = false
                        case .records: needsRecords = false
                        default: break
                        }
                        if !needsClients && !needsSessions && !needsRecords { return }
                    }
                    throw ReshError("Rex \(kind.rawValue) stream ended before its initial snapshot.")
                }
                tasks.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw ReshError("Timed out waiting for Rex \(kind.rawValue) snapshot.")
                }
                defer { tasks.cancelAll() }
                try await tasks.next()
            }
        }
    }

    @Test @MainActor func numberedShortcutsSkipTheCurrentSession() async throws {
        let stub = try StubRex(body: """
        import pathlib
        if 'client' in sys.argv:
            print('{"clients":[{"client_id":"client:test","info":{"kind":"app","platform":"macos"}}]}')
        elif 'session.select' in sys.argv:
            pathlib.Path(__file__+'.selected').write_text(json.loads(sys.argv[sys.argv.index('--args')+1])['session_id'])
            print('{}')
        else:
            raise Exception('Unexpected command')
        """)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test")),
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
        let selected = stub.directory.appendingPathComponent("rex.selected")
        #expect(try String(contentsOf: selected, encoding: .utf8) == "a")
    }

    @Test(arguments: ["local", "remote", "none"], [false, true])
    @MainActor func createsNamedSessions(activeHost: String, selectionRefused: Bool) async throws {
        let stub = try StubRex(body: """
        import pathlib
        root=pathlib.Path(__file__).parent
        server=sys.argv[sys.argv.index('--server')+1]
        if 'client' in sys.argv:
            assert server=='home'
            print('{"clients":[{"client_id":"client:test","info":{"kind":"app","platform":"macos"}}]}')
        elif 'hosts' in sys.argv:
            print(json.dumps({'hosts':[{'host':{'id':'host:build','label':'build','endpoints':['https://build.example']}}]}))
        elif 'actions' in sys.argv:
            print('{"actions":[]}')
        elif 'ls' in sys.argv:
            sessions=[{'session_id':'local' if server=='home' else 'remote','label':'Work'}]
            if server=='\(activeHost == "remote" ? "build" : "home")': sessions.append({'session_id':'new','label':'Scratch'})
            print(json.dumps({'sessions':sessions}))
        elif 'session.create' in sys.argv:
            assert server=='\(activeHost == "remote" ? "build" : "home")'
            args=json.loads(sys.argv[-1])
            block=args['initial_windows'][0]['layout']['block']
            assert args['label']=="Scratch 'notes'"
            assert block['flavor']=='com.superlogical.terminal.shell' and not block['options']
            with (root/'creations').open('a') as f: f.write('1')
            print('{"session_id":"new"}')
        elif 'session.select' in sys.argv:
            assert server=='home' and sys.argv[sys.argv.index('-C')+1]=='client:test'
            if (root/'refuse').exists():
                (root/'refuse').unlink()
                print('Remote Control disabled',file=sys.stderr)
                sys.exit(1)
            (root/'selected').write_text(json.loads(sys.argv[sys.argv.index('--args')+1])['session_id'])
            print('{}')
        else:
            raise Exception('Unexpected command')
        """)
        if selectionRefused { try Data().write(to: stub.directory.appendingPathComponent("refuse")) }
        let config = stub.directory.appendingPathComponent("config.toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test", server: "home")),
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
        #expect(try String(contentsOf: stub.directory.appendingPathComponent("selected"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: stub.directory.appendingPathComponent("creations"), encoding: .utf8) == "1")
        if activeHost != "none" {
            let created = Candidate(id: Candidate.identity("new", host: expectedHost), kind: .session,
                title: "Scratch", sessionID: "new", host: expectedHost)
            #expect(try await service.connectLast(from: created) == activeHost)
            focus = "new"
            model.receive(.success(.created("new")), host: expectedHost)
            let previous = expectedHost == nil ? sessions : [RexSession(sessionID: "remote", label: "Build")]
            model.receive(.success(.sessions(previous + [RexSession(sessionID: "new", label: "Scratch")])), host: expectedHost)
            await model.catalog.refreshHistory().value
            #expect(try await service.recentSessionIDs() == Array(expectedHistory.reversed()))
        }
    }

    @Test @MainActor func creationWaitsForTheActiveHost() async throws {
        let stub = try StubRex(body: """
        if 'hosts' in sys.argv:
            print(json.dumps({'hosts':[{'host':{'id':'host:build','label':'build','endpoints':['https://build.example']}}]}))
        elif 'actions' in sys.argv:
            print('{"actions":[]}')
        else:
            raise Exception('Unexpected command')
        """)
        let config = stub.directory.appendingPathComponent("config.toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test")))
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

    @Test(arguments: [false, true])
    @MainActor func launcherCommandsUseResidentHistory(_ cached: Bool) async throws {
        let stub = try StubRex(body: """
        import pathlib
        root=pathlib.Path(__file__).parent.resolve()
        if 'client' in sys.argv:
            print('{"clients":[{"client_id":"client:test","info":{"kind":"app","platform":"macos"}}]}')
        elif 'ls' in sys.argv:
            sessions=[{'session_id':'a','label':'First'}]
            if (root/'created').exists(): sessions.append({'session_id':'b','label':'Project'})
            print(json.dumps({'sessions':sessions}))
        elif 'session.create' in sys.argv:
            args=json.loads(sys.argv[-1])
            options=args['initial_windows'][0]['layout']['block']['options']
            assert args['label']=='Project' and pathlib.Path(options['cwd']).resolve()==root/'project'
            assert options['initial_input']=='true\\n'
            (root/'created').touch()
            print('{"session_id":"b"}')
        elif 'session.select' in sys.argv:
            print('{}')
        else:
            raise Exception('Unexpected command')
        """)
        let folder = stub.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = stub.directory.appendingPathComponent("config.toml")
        try """
        [[session]]
        name = "Project"
        path = "project"
        startup_command = "true"
        """.write(to: config, atomically: true, encoding: .utf8)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test")),
            registry: SessionRegistry(directory: stub.directory))
        let commands = LauncherCommands(service: service, configurationURL: config,
            sessions: cached ? ReshService.candidates(from: [RexSession(sessionID: "a", label: "First")]) : [])
        let name = "resh-tests." + UUID().uuidString
        let host = try LauncherHost(name: name as CFString)
        defer { host.stop() }
        host.onRequest = { request in
            do { return try await commands.run(request) }
            catch { return ["error": error.localizedDescription] }
        }
        func send(_ request: LauncherRequest) async throws -> [String: Any] {
            try #require(await Task.detached { try LauncherIPC.send(request, name: name as CFString) }.value)
        }
        var last = LauncherRequest(operation: "last", client: "client:test", currentSessionID: "a")
        #expect(try await send(last).isEmpty)
        let connected = try await send(LauncherRequest(operation: "connect", client: "client:test", currentSessionID: "a", path: ".", cwd: folder.path))
        #expect(connected["session_id"] as? String == "b")
        #expect(connected["path"] as? String == folder.resolvingSymlinksInPath().path)
        #expect(try await service.recentSessionIDs() == ["b", "a"])
        last.currentSessionID = "b"
        #expect(try await send(last)["session_id"] as? String == "a")
        #expect(try await service.recentSessionIDs() == ["a", "b"])
        last.currentSessionID = "a"
        #expect(try await send(last)["session_id"] as? String == "b")
        #expect(try await service.recentSessionIDs() == ["b", "a"])
        await #expect(throws: ReshError.self) {
            try await send(LauncherRequest(operation: "connect", client: "client:test", path: "missing", cwd: folder.path))
        }
        #expect(try await service.recentSessionIDs() == ["b", "a"])
    }

    @Test func snapshotRecoversAfterDisconnect() throws {
        let stub = try StubRex(body: """
        import pathlib
        marker=pathlib.Path(__file__+'.started')
        first=not marker.exists()
        marker.touch()
        print('{"ready":true}',flush=True)
        for line in sys.stdin:
            if first:
                print('{"error":"reading API control: EOF"}',flush=True)
            else:
                print('{"client":"client:test","rex_app_pid":1,"sessions":[{"session_id":"s","label":"Session"}]}',flush=True)
        """)
        let connection = RexDataConnection(tools: stub.tools)
        defer { connection.stop() }
        let snapshot = try connection.snapshot(target: RexTarget(clientID: "client:test"))
        #expect(snapshot.sessions.map(\.label) == ["Session"])
    }

    @Test func attentionStreamHandlesFragmentsEmptySnapshotsAndExplicitTarget() async throws {
        let stub = try StubRex(body: """
        import os
        assert not any(k in os.environ for k in ['REX_SESSION','REX_BLOCK','REX_CLIENT','REX_SERVER'])
        server=sys.argv[sys.argv.index('--server')+1]
        assert '--all' in sys.argv
        print(json.dumps({'type':'sessions','sessions':[{'session_id':server,'label':'Session'}]}),flush=True)
        data=json.dumps({'records':[{'session_id':server,'block_id':'b','state':'done','updated_at':'2026-10-22T17:59:59Z'}]})
        sys.stdout.write(data[:12]);sys.stdout.flush();time.sleep(.02)
        print(data[12:],flush=True)
        print('{"heartbeat":true}',flush=True)
        print('{"type":"sessions"}',flush=True)
        print('{}',flush=True)
        time.sleep(30)
        """)
        let connection = RexEventConnection(tools: stub.tools), updates = AttentionUpdates()
        defer { connection.stop() }
        connection.start(target: RexTarget(server: "explicit-server")) { updates.append($0) }
        try await updates.waitForCount(2)
        #expect(updates.values.first?.first?.sessionID == "explicit-server")
        #expect(updates.values.last?.isEmpty == true)
        #expect(updates.values.count == 2) // Heartbeat must not clear an unread dot.
        #expect(updates.sessions.first?.first?.sessionID == "explicit-server")
        #expect(updates.sessions.count == 2 && updates.sessions.last?.isEmpty == true)
        connection.stop()
        let count = updates.values.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(updates.values.count == count)
        connection.start(target: RexTarget(server: "new-server")) { updates.append($0) }
        try await updates.waitForCount(count + 2)
        #expect(updates.values[count].first?.sessionID == "new-server")
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

    @Test func returnsNewLinesWithoutWaitingForPipeEOF() throws {
        let stub = try StubRex(body: """
        print('{"ready":true}',flush=True)
        n=0
        for line in sys.stdin:
            n+=1
            print(json.dumps({'client':'client:test','rex_app_pid':1,'sessions':[{'session_id':'session:test','label':str(n)}]}),flush=True)
        """)
        let connection = RexDataConnection(tools: stub.tools, timeout: 1)
        defer { connection.stop() }
        #expect(try connection.snapshot(target: RexTarget(), rexAppPID: 1).sessions.first?.label == "1")
        let start = ProcessInfo.processInfo.systemUptime
        #expect(try connection.snapshot(target: RexTarget(), rexAppPID: 1).sessions.first?.label == "2")
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.5)
    }

    @Test func stalledResponseTimesOutAndCanBeStopped() throws {
        let stub = try StubRex(body: """
        print('{"ready":true}',flush=True)
        for line in sys.stdin:
            time.sleep(30)
        """)
        let connection = RexDataConnection(tools: stub.tools, timeout: 1)
        defer { connection.stop() }
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: ReshError.self) { try connection.snapshot(target: RexTarget(), rexAppPID: 1) }
        connection.stop()
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor func catalogStaysCurrentBetweenPresentations(presented: Bool, events: Bool) async throws {
        let stub = try StubRex(body: """
        import pathlib
        root=pathlib.Path(__file__).parent
        if 'hosts' in sys.argv:
            print('{"hosts":[]}')
        elif 'kill' in sys.argv:
            (root/'closed').touch()
            print('{}')
        else:
            print('{"type":"clients","clients":[{"client":"client:test","rex_app_pid":42}]}',flush=True)
            print('{"type":"sessions","sessions":[{"session_id":"s","label":"First"}]}',flush=True)
            while not (root/'changed').exists(): time.sleep(.01)
            if \(events ? "True" : "False"): print('{"type":"created","session_id":"new"}',flush=True)
            print('{"type":"sessions","sessions":[{"session_id":"s","label":"Renamed"},{"session_id":"new","label":"New"}]}',flush=True)
            while not (root/'closed').exists(): time.sleep(.01)
            if \(events ? "True" : "False"): print('{"type":"destroyed","session_id":"new"}',flush=True)
            print('{"type":"sessions","sessions":[{"session_id":"s","label":"Renamed"}]}',flush=True)
            time.sleep(30)
        """)
        let config = stub.directory.appendingPathComponent("config.toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget()),
            registry: SessionRegistry(directory: stub.directory))
        let selectedService = service.at(RexTarget(clientID: "client:test"))
        var focus = "s"
        let model = SearchModel(service: service, tools: stub.tools, configurationURL: config,
            readTheme: { _, _ in .fixture }, readFocusedSession: { _ in focus })
        defer { model.clear() }
        model.startBackground()
        await model.loadingTask?.value
        for _ in 0..<300 {
            if model.results.first?.title == "First", model.catalog.recentSessionIDs["client:test"] == ["s"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.results.map(\.title) == ["First"])
        model.query = "first"
        model.endPresentation()
        #expect(model.query.isEmpty && model.results.map(\.title) == ["First"])
        try "".write(to: stub.directory.appendingPathComponent("changed"), atomically: true, encoding: .utf8)
        for _ in 0..<300 {
            if model.results.first?.title == "Renamed" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try #require(model.catalog.snapshot(clientID: nil, rexAppPID: 42))
        #expect(snapshot.client == "client:test" && snapshot.sessions.map(\.label) == ["Renamed", "New"])
        #expect(try await selectedService.recentSessionIDs() == ["s"])
        focus = "new"
        if presented { model.prepare(service: selectedService, sessions: snapshot.sessions, rexAppPID: 42, currentSessionID: focus) }
        else { model.refreshFocus() }
        for _ in 0..<300 where model.catalog.recentSessionIDs["client:test"] != ["new", "s"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.catalog.recentSessionIDs["client:test"] == ["new", "s"])
        if presented {
            #expect(model.results.map(\.title) == ["New", "Renamed"])
            #expect(model.numberedRows.map { model.results[$0].id } == ["s"])
        }
        #expect(!model.isLoading)
        if presented { model.selection = 0; model.deleteSelection() }
        else {
            try "".write(to: stub.directory.appendingPathComponent("closed"), atomically: true, encoding: .utf8)
            for _ in 0..<300 where model.sessionCount != 1 { try await Task.sleep(for: .milliseconds(10)) }
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
        let stub = try StubRex(body: """
        if 'hosts' in sys.argv:
            print('{"hosts":[]}')
        elif 'client' in sys.argv:
            print('{"clients":[{"client_id":"client:test","info":{"kind":"app","platform":"macos"}}]}')
        elif 'ls' in sys.argv:
            print('{"sessions":[{"session_id":"current","label":"Current"}]}')
        elif 'session.select' in sys.argv:
            print('Remote Control disabled',file=sys.stderr)
            sys.exit(1)
        else:
            raise Exception('Unexpected command')
        """)
        let provider = SnapshotStub([
            .success(RexSnapshot(client: "client:test", rexAppPID: 1, sessions: [RexSession(sessionID: "new", label: "Fresh session")])),
        ])
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test")),
            registry: SessionRegistry(directory: stub.directory))
        let model = SearchModel(service: service, tools: stub.tools,
            sessions: [RexSession(sessionID: "old", label: "Session")],
            snapshotProvider: provider, readTheme: { _, _ in .fixture })
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

    @Test func explicitClientAndAppPIDUseTheSameConnectionAndBundledScript() throws {
        let stub = try StubRex(body: """
        import os
        assert os.path.isfile(sys.argv[sys.argv.index('do')+1])
        print('{"ready":true}',flush=True)
        for line in sys.stdin:
            request=json.loads(line)
            assert ('client' in request) != ('rex_app_pid' in request)
            print(json.dumps({'client':request.get('client','client:app'),'rex_app_pid':os.getpid()}),flush=True)
        """)
        let connection = RexDataConnection(tools: stub.tools)
        defer { connection.stop() }
        let native = try connection.snapshot(target: RexTarget(), rexAppPID: 42)
        let action = try connection.snapshot(target: RexTarget(clientID: "client:explicit"))
        #expect(native.client == "client:app" && action.client == "client:explicit")
        #expect(native.rexAppPID == action.rexAppPID && native.sessions.isEmpty && action.sessions.isEmpty)
    }

    @Test func optionalIntegrationChecksHaveOneBoundedDeadline() throws {
        let stub = try StubRex(body: """
        if 'actions' in sys.argv:
            print(json.dumps({'actions':[{'name':'resh_info','kind':'lua'},{'name':'resh_query','kind':'lua'}]}))
        else:
            time.sleep(30)
        """)
        let remote = RexRemote(client: RexClient(tools: stub.tools, target: RexTarget(server: "build")))
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: ReshError.self) { try remote.functions(timeout: 0.2) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test @MainActor func hostUpdatesPreserveSelection() async throws {
        let stub = try StubRex(body: """
        if 'hosts' in sys.argv:
            print(json.dumps({'hosts':[{'host':{'id':'host:build','label':'build','endpoints':['https://build.example']}}]}))
        elif 'actions' in sys.argv:
            print('{"actions":[]}')
        else:
            raise Exception('Unexpected command')
        """)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget()))
        let local = RexSession(sessionID: "local", label: "api")
        let model = SearchModel(service: service, tools: stub.tools, sessions: [local],
            recentSessionIDs: ["host:build/remote", "local"],
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
        let stub = try StubRex(body: """
        import pathlib
        if 'hosts' in sys.argv:
            print(json.dumps({'hosts':[{'host':{'id':name,'label':name,'endpoints':['https://'+name]}} for name in ['first','second']]}))
        elif 'actions' in sys.argv:
            print(json.dumps({'actions':[] if sys.argv[sys.argv.index('--server')+1]=='first' else [{'name':'resh_info','kind':'lua'},{'name':'resh_query','kind':'lua'}]}))
        elif 'resh_info' in sys.argv:
            enabled='\(scenario)'=='remote' and not pathlib.Path(__file__+'.disabled').exists()
            print(json.dumps({'version':1,'functions':['resolve','zoxide'] if enabled else []}))
        else:
            print('{}')
        """)
        let config = stub.directory.appendingPathComponent("config.toml")
        let text = scenario == "projects" ? "[[session]]\nname = 'Project'\npath = '.'\n"
            : scenario == "custom" ? "source_order = ['find']\ninitial_source = 'find'\n" : ""
        try text.write(to: config, atomically: true, encoding: .utf8)
        let tools = Tools(rex: stub.tools.rex, zoxide: nil, fd: scenario == "local" ? "/usr/bin/true" : nil, rexApp: stub.tools.rexApp)
        let model = SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget())),
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
            try "".write(to: stub.directory.appendingPathComponent("rex.disabled"), atomically: true, encoding: .utf8)
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
