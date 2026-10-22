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

@Suite("Resident data connection")
struct DataConnectionTests {
    @Test func returnsNewLinesWithoutWaitingForPipeEOF() throws {
        let stub = try StubRex(body: """
        print('{"ready":true}',flush=True)
        n=0
        for line in sys.stdin:
            n+=1
            print(json.dumps({'client':'client:test','sessions':[{'session_id':'session:test','label':str(n)}]}),flush=True)
        """)
        let connection = RexDataConnection(tools: stub.tools, timeout: 1)
        defer { connection.stop() }
        try connection.warmup()
        let start = ProcessInfo.processInfo.systemUptime
        #expect(try connection.snapshot(appPID: 1).sessions?.first?.label == "1")
        #expect(try connection.snapshot(appPID: 1).sessions?.first?.label == "2")
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
        #expect(throws: ReshError.self) { try connection.snapshot(appPID: 1) }
        connection.stop()
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test @MainActor func hidingClearsDataAndNextOpeningReplacesIt() {
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()))
        let model = SearchModel(service: service, tools: tools, sessions: [RexSession(sessionID: "first", label: "first")])
        model.query = "first"
        model.clear()
        #expect(model.query.isEmpty && model.results.isEmpty && model.sessionCount == 0)
        model.prepare(service: service, sessions: [RexSession(sessionID: "second", label: "second")])
        #expect(model.results.map(\.title) == ["second"])
        #expect(!model.isLoading)
    }
}
