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
    private var failures: [String] = []
    var values: [[RexAttentionRecord]] { lock.lock(); defer { lock.unlock() }; return updates }
    var sessions: [[RexSession]] { lock.lock(); defer { lock.unlock() }; return sessionUpdates }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return failures }
    func append(_ result: Result<RexAttentionUpdate, Error>) {
        lock.lock(); defer { lock.unlock() }
        switch result {
        case let .success(.records(records)): updates.append(records)
        case let .success(.sessions(sessions)): sessionUpdates.append(sessions)
        case .success(.hostsChanged), .success(.capabilitiesChanged): break
        case let .failure(error): updates.append([]); failures.append(error.localizedDescription)
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

@Suite("Resident data connection")
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
        let connection = RexAttentionConnection(tools: stub.tools), updates = AttentionUpdates()
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

    @Test func attentionStreamReportsMalformedDataAndRecoversFromEOF() async throws {
        for ending in ["print('not json',flush=True);time.sleep(30)", "sys.exit(0)"] {
            let stub = try StubRex(body: """
            print('{"records":[{"session_id":"s","block_id":"b","state":"done","updated_at":"2026-10-22T17:59:59Z"}]}',flush=True)
            time.sleep(.03)
            \(ending)
            """)
            let connection = RexAttentionConnection(tools: stub.tools), updates = AttentionUpdates()
            connection.start(target: RexTarget()) { updates.append($0) }
            defer { connection.stop() }
            try await updates.waitForCount(ending == "sys.exit(0)" ? 3 : 2)
            #expect(updates.values.first?.first?.state == "done")
            if ending == "sys.exit(0)" {
                #expect(updates.values.last?.first?.state == "done")
                #expect(updates.errors.isEmpty)
            } else {
                #expect(updates.values.last?.isEmpty == true)
                #expect(updates.errors.count == 1)
            }
        }
    }

    @Test func unavailableAttentionConnectionReportsFailure() async throws {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let connection = RexAttentionConnection(tools: tools), updates = AttentionUpdates()
        defer { connection.stop() }
        connection.start(target: RexTarget()) { updates.append($0) }
        try await updates.waitForCount(1)
        #expect(updates.values == [[]])
        #expect(updates.errors.count == 1)
    }

    @Test func activityAPIErrorsAreNotTurnedIntoEmptySuccessfulSnapshots() async throws {
        let stub = try StubRex(body: """
        print('{"error":"program_status API is unavailable"}',flush=True)
        time.sleep(30)
        """)
        let updates = AttentionUpdates(), connection = RexAttentionConnection(tools: stub.tools)
        defer { connection.stop() }
        connection.start(target: RexTarget()) { updates.append($0) }
        try await updates.waitForCount(1)
        #expect(updates.errors == ["program_status API is unavailable"])
    }

    @Test func failedSnapshotIsNotRetriedThroughAnotherCommand() throws {
        let stub = try StubRex(body: """
        print('{"ready":true}',flush=True)
        for line in sys.stdin:
            print('{"error":"Cannot read sessions"}',flush=True)
        """)
        let connection = RexDataConnection(tools: stub.tools)
        defer { connection.stop() }
        do {
            _ = try connection.snapshot(target: RexTarget(clientID: "client:test"))
            Issue.record("Expected the snapshot error")
        } catch {
            #expect(error.localizedDescription == "Cannot read sessions")
        }
    }

    @Test @MainActor func liveUpdatesPreserveSearchAndSelectionAndAreClearedOnHide() async throws {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()))
        let sessions = [RexSession(sessionID: "first", label: "Session one"), RexSession(sessionID: "second", label: "Session two")]
        let model = try SearchModel(service: service, tools: tools, sessions: sessions,
            readTheme: { _, _ in .fixture }, readPreferences: { ["Workspace.programActivitySeen": [:]] })
        model.query = "session"; model.selection = 1
        let results = model.results
        let record = RexAttentionRecord(sessionID: "first", blockID: "synthetic", state: "done", updatedAt: "2026-10-22T17:59:59Z")
        model.updateAttention([record])
        await model.attentionTask?.value
        #expect(model.attentionSessionIDs == ["first"])
        #expect(model.results == results && model.query == "session" && model.selection == 1)
        model.receiveAttention(.success(.sessions([
            RexSession(sessionID: "new", label: "Session new"), sessions[0],
            RexSession(sessionID: "second", label: "Session renamed"),
        ])))
        #expect(model.sessionCount == 3 && model.results.count == 3)
        #expect(model.selected?.id == "second" && model.selected?.title == "Session renamed")
        #expect(model.query == "session")
        let updatedResults = model.results
        model.receiveAttention(.failure(ReshError("Unavailable")))
        #expect(model.results == updatedResults && model.selected?.id == "second" && model.query == "session")
        #expect(model.attentionSessionIDs == ["first"] && model.displayedError == nil)
        model.receiveAttention(.success(.sessions([])))
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
        try connection.warmup()
        let start = ProcessInfo.processInfo.systemUptime
        #expect(try connection.snapshot(target: RexTarget(), rexAppPID: 1).sessions.first?.label == "1")
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
        try connection.warmup()
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: ReshError.self) { try connection.snapshot(target: RexTarget(), rexAppPID: 1) }
        connection.stop()
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test @MainActor func hidingClearsDataAndNextOpeningReplacesIt() throws {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()))
        let model = try SearchModel(service: service, tools: tools,
            sessions: [RexSession(sessionID: "first", label: "first")], readTheme: { _, _ in .fixture })
        model.query = "first"
        model.clear()
        #expect(model.query.isEmpty && model.results.isEmpty && model.sessionCount == 0)
        model.prepare(service: service, sessions: [RexSession(sessionID: "second", label: "second")])
        #expect(model.results.map(\.title) == ["second"])
        #expect(!model.isLoading)
    }

    @Test @MainActor func reloadUsesTheSnapshotProviderAndReportsFailureWithoutAnotherTransport() async throws {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let provider = SnapshotStub([
            .success(RexSnapshot(client: "client:test", rexAppPID: 1, sessions: [RexSession(sessionID: "new", label: "Fresh")])),
            .failure(ReshError("Snapshot connection failed")),
        ])
        let model = try SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget(clientID: "client:test"))),
            tools: tools, snapshotProvider: provider, readTheme: { _, _ in .fixture })
        model.loadInitial()
        await model.loadingTask?.value
        #expect(provider.calls == 0 && model.results.isEmpty)
        model.reload()
        await model.loadingTask?.value
        #expect(provider.calls == 1 && model.results.map(\.title) == ["Fresh"])
        model.reload()
        await model.loadingTask?.value
        #expect(provider.calls == 2 && model.error == "Snapshot connection failed")
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

    @Test @MainActor func unreadFailuresAreVisibleWithoutPretendingStatusesAreUnread() async throws {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let model = try SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget())),
            tools: tools, readTheme: { _, _ in .fixture }, readPreferences: { [:] })
        model.updateAttention([RexAttentionRecord(sessionID: "s", blockID: "b", state: "done", updatedAt: "2026-10-22T17:59:59Z")])
        await model.attentionTask?.value
        #expect(model.attentionSessionIDs.isEmpty)
        #expect(model.displayedError?.contains("read receipts are unavailable") == true)
        let diagnostic = model.displayedError
        model.receiveAttention(.failure(ReshError("program_status is unavailable")))
        #expect(model.displayedError == diagnostic)
        model.receiveAttention(.success(.records([])))
        #expect(model.displayedError == nil)
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

    @Test @MainActor func hostUpdatesPreserveSelectionAndFailuresStayIsolated() async throws {
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
        let model = try SearchModel(service: service, tools: stub.tools, sessions: [local],
            recentSessionIDs: ["host:build/remote", "local"],
            readTheme: { _, _ in .fixture }, readPreferences: { ["Workspace.programActivitySeen": [:]] })
        defer { model.clear() }
        model.loadInitial()
        await model.loadingTask?.value
        await model.hostsTask?.value
        let host = try #require(model.hosts.first)
        model.receiveAttention(.success(.sessions([RexSession(sessionID: "remote", label: "api")])), host: host)
        #expect(model.results.count == 2 && model.showsHosts)
        #expect(model.results.map(\.id) == ["host:build/remote", "local"])
        model.query = "api build"
        #expect(model.results.count == 1 && model.selected?.host == host && model.showsHosts)
        let selectedID = model.selected?.id
        model.receiveAttention(.success(.sessions([RexSession(sessionID: "another", label: "api"), local])))
        #expect(model.selected?.id == selectedID && model.query == "api build")
        model.receiveAttention(.success(.records([RexAttentionRecord(sessionID: "remote", blockID: "b", state: "done", updatedAt: "2026-10-23T12:00:00Z")])), host: host)
        await model.attentionTask?.value
        #expect(model.attentionSessionIDs == [Candidate.identity("remote", host: host)])
        let results = model.results, sources = model.visibleSources.map(\.id)
        let loading = model.isRemoteLoading, diagnostic = model.displayedError
        model.receiveAttention(.failure(ReshError("Host unavailable")), host: host)
        #expect(model.results == results && model.query == "api build" && model.selected?.id == selectedID)
        #expect(model.sessionCount == 3 && model.attentionSessionIDs == [Candidate.identity("remote", host: host)])
        #expect(model.displayedError == diagnostic && model.isRemoteLoading == loading)
        #expect(model.visibleSources.map(\.id) == sources)
        #expect(model.showsHosts)
        model.receiveAttention(.success(.sessions([RexSession(sessionID: "new", label: "api")])), host: host)
        #expect(model.sessionCount == 3)
        for _ in 0..<200 where model.visibleSources.map(\.id) != [.sessions] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.visibleSources.map(\.id) == [.sessions])
    }

    @Test(arguments: ["none", "local", "remote", "projects", "unknown", "custom"])
    @MainActor func sourceAvailability(_ scenario: String) async throws {
        let stub = try StubRex(body: """
        import pathlib
        if 'hosts' in sys.argv:
            print(json.dumps({'hosts':[{'host':{'id':name,'label':name,'endpoints':['https://'+name]}} for name in ['first','second']]}))
        elif 'actions' in sys.argv:
            print(json.dumps({'actions':[] if sys.argv[sys.argv.index('--server')+1]=='first' else [{'name':'resh_info','kind':'lua'},{'name':'resh_query','kind':'lua'}]}))
        elif 'resh_info' in sys.argv:
            if '\(scenario)'=='unknown':
                sys.stderr.write('Unavailable');sys.exit(1)
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
        let model = try SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget())),
            tools: tools, configurationURL: config, readTheme: { _, _ in .fixture })
        defer { model.clear() }
        let expected: [SearchScope]
        switch scenario {
        case "local": expected = [.sessions, .find]
        case "remote": expected = [.sessions, .all, .directories]
        case "projects": expected = [.sessions, .all, .configs]
        case "unknown": expected = [.sessions, .all, .directories, .find]
        default: expected = [.sessions]
        }
        func waitForSources(_ sources: [SearchScope]) async throws {
            for _ in 0..<200 {
                if model.visibleSources.map(\.id) == sources,
                   scenario != "unknown" || model.diagnostic?.contains("Unavailable") == true { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Source availability did not update")
        }
        model.loadInitial()
        await model.loadingTask?.value
        await model.hostsTask?.value
        try await waitForSources(expected)
        for host in model.hosts { model.receiveAttention(.success(.sessions([])), host: host) }
        if scenario == "remote" {
            model.changeScope(.directories)
            await model.loadingTask?.value
            for _ in 0..<200 where model.isRemoteLoading { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.results.isEmpty && model.visibleSources.map(\.id) == expected && model.displayedError == nil)
            try "".write(to: stub.directory.appendingPathComponent("rex.disabled"), atomically: true, encoding: .utf8)
            let host = try #require(model.hosts.first { $0.label == "second" })
            model.receiveAttention(.success(.capabilitiesChanged), host: host)
            try await waitForSources([.sessions])
            #expect(model.scope == .sessions)
            model.changeScope(.directories)
            model.cycleSource(1)
            #expect(model.scope == .sessions)
        }
    }
}
