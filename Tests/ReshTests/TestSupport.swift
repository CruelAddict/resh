import Foundation
import ReshCore
import Testing
@testable import Resh

@Suite("Picker behavior", .serialized)
struct PickerTests {}

extension RexTheme {
    static var fixture: RexTheme {
        .fallback(systemIsDark: true)
    }
}

extension KeyboardLayouts {
    static let fixture = KeyboardLayouts([
        "qwertyuiop[]asdfghjkl;'zxcvbnm,./`",
        "йцукенгшщзхъфывапролджэячсмитьбю.ё",
        "qwertzuiopü+asdfghjklöäyxcvbnm,.-^",
    ].map { ($0 + $0.uppercased()).map(String.init) })
}

final class SnapshotStub: RexSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<RexSnapshot, Error>]
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(_ responses: [Result<RexSnapshot, Error>]) { self.responses = responses }

    func snapshot(target: RexTarget, rexAppPID: Int32?) throws -> RexSnapshot {
        lock.lock(); defer { lock.unlock() }
        count += 1
        guard !responses.isEmpty else { throw ReshError("Unexpected snapshot request") }
        return try responses.removeFirst().get()
    }
}

final class RexBridgeStub: CommandRunning {
    let directory: URL
    let tools: Tools

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("resh-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("rex")
        tools = Tools(rex: executable.path, zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        try saveHosts([])
        try #"""
        #!/usr/bin/python3 -u
        import json, sys
        from pathlib import Path
        attached = False
        def reply(value):
            print(json.dumps(value), flush=True)
        hosts = json.loads((Path(__file__).parent / 'hosts.json').read_text())
        server = sys.argv[sys.argv.index('--server') + 1]
        host = next((host for host in hosts if host['label'] == server), None)
        endpoint = host['endpoints'][0] if host else server
        reply({'ready': True})
        for line in sys.stdin:
            request = json.loads(line)
            method, args = request.get('method'), request.get('args', {})
            if method == 'session.attach_all':
                attached = True
                reply({'result': {'sessions': []}})
            elif method == 'client.list':
                reply({'result': {'clients': [{'client_id': 'client:test', 'info': {'kind': 'app', 'platform': 'macos'}}]}})
            elif method == 'session.create':
                reply({'result': {'session_id': endpoint + '/' + args['label']}})
            elif method == 'client.perform':
                reply({'result': {'performed_by': args['client_id']}})
            elif method == 'session.focus_block':
                if attached:
                    reply({'result': {'revision': 1}})
                else:
                    reply({'error': 'stream is not attached to session ' + args['session_id']})
            else:
                reply({'error': 'Unexpected method: ' + str(method)})
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func saveHosts(_ hosts: [RexHost]) throws {
        try JSONEncoder().encode(hosts).write(to: directory.appendingPathComponent("hosts.json"), options: .atomic)
    }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, directory: String?) throws -> CommandResult {
        guard executable == tools.rex, arguments.contains("hosts") else { throw ReshError("Unexpected command: \(arguments)") }
        // Keep Python startup outside the host catalog's two-second command budget.
        // The bridge still reads this same file when each real connection starts.
        let hosts = try JSONDecoder().decode([RexHost].self, from: Data(contentsOf: self.directory.appendingPathComponent("hosts.json")))
        return CommandResult(stdout: try JSONSerialization.data(withJSONObject: [
            "hosts": hosts.map { ["host": ["id": $0.id, "label": $0.label, "endpoints": $0.endpoints]] },
        ]))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
