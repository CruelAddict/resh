import Foundation
import ReshCore
import Testing
@testable import Resh

// Serialize independent integration scenarios, not their background work.
@Suite("Rex integration", .serialized)
struct IntegrationTests {}

extension RexTheme {
    static var fixture: RexTheme {
        try! resolve(preferences: ["Workspace.darkThemeID": "fixture"], builtins: Data("""
        [{"id":"fixture","source":{"background":"#161616","foreground":"#eeeeee"},
        "semantic":{"accentSolid":"#cc6600","selection":"#cc6600","surfaceRaised":"#262626","infoSolid":"#4488cc"}}]
        """.utf8), systemIsDark: true)
    }
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
