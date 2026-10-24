import Foundation
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
        case .success(.hostsChanged), .success(.capabilitiesChanged), .success(.clients), .success(.reconnecting): break
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

    @Test @MainActor func catalogStaysCurrentBetweenPresentations() async throws {
        let stub = try StubRex(body: """
        import pathlib
        root=pathlib.Path(__file__).parent
        if 'hosts' in sys.argv:
            print('{"hosts":[]}')
        else:
            print('{"type":"clients","clients":[{"client":"client:test","rex_app_pid":42}]}',flush=True)
            print('{"type":"sessions","sessions":[{"session_id":"s","label":"First"}]}',flush=True)
            while not (root/'changed').exists(): time.sleep(.01)
            print('{"type":"sessions","sessions":[{"session_id":"s","label":"Renamed"}]}',flush=True)
            time.sleep(30)
        """)
        let config = stub.directory.appendingPathComponent("config.toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        let service = ReshService(client: RexClient(tools: stub.tools, target: RexTarget(clientID: "client:test")),
            registry: SessionRegistry(directory: stub.directory))
        let model = SearchModel(service: service, tools: stub.tools, configurationURL: config,
            readTheme: { _, _ in .fixture })
        defer { model.clear() }
        model.startBackground()
        await model.loadingTask?.value
        for _ in 0..<300 {
            if model.results.first?.title == "First" { break }
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
        #expect(snapshot.client == "client:test" && snapshot.sessions.map(\.label) == ["Renamed"])
        model.prepare(service: service, sessions: snapshot.sessions)
        #expect(model.results.map(\.title) == ["Renamed"])
        #expect(!model.isLoading)
    }

    @Test @MainActor func reloadUsesTheSnapshotProvider() async {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let provider = SnapshotStub([
            .success(RexSnapshot(client: "client:test", rexAppPID: 1, sessions: [RexSession(sessionID: "new", label: "Fresh")])),
        ])
        let model = SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget(clientID: "client:test"))),
            tools: tools, snapshotProvider: provider, readTheme: { _, _ in .fixture })
        model.loadInitial()
        await model.loadingTask?.value
        #expect(provider.calls == 0 && model.results.isEmpty)
        model.reload()
        await model.loadingTask?.value
        #expect(provider.calls == 1 && model.results.map(\.title) == ["Fresh"])
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
