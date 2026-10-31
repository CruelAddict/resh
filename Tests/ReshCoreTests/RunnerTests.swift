import Darwin
import Foundation
import Testing
@testable import ReshCore

// Advance the deadline only after the shell has reached the scenario under test.
// Process startup and runner scheduling must not consume a CI timing budget.
private final class CommandClock: @unchecked Sendable {
    private let ready: URL
    private let lock = NSLock()
    private var started = false

    init(ready: URL) { self.ready = ready }

    func now() -> TimeInterval {
        lock.lock(); defer { started = true; lock.unlock() }
        return started && FileManager.default.fileExists(atPath: ready.path) ? 2 : 0
    }
}

@Suite("Subprocess execution", .serialized, .timeLimit(.minutes(1)))
struct RunnerTests {
    @Test(arguments: [[], ["--remote"]])
    func missingInstallationOptionValue(_ options: [String]) throws {
        let installer = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh")
        let result = try SystemCommandRunner().run("/bin/bash", [installer.path] + options + ["--source"], timeout: 30)
        #expect(result.status != 0)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("Missing value for --source"))
    }

    @Test func reportsFailureAndCapsOutput() throws {
        let runner = SystemCommandRunner()
        #expect(try runner.run("/usr/bin/false", [], timeout: 30).status == 1)
        #expect(throws: ReshError.self) {
            try runner.run("/usr/bin/head", ["-c", "2097153", "/dev/zero"], timeout: 30)
        }
    }
    @Test(arguments: [false, true])
    func timeoutCoversTheEntireProcess(_ closeOutput: Bool) throws {
        let temporary = try TemporaryDirectory(), ready = temporary.url.appendingPathComponent("ready")
        let clock = CommandClock(ready: ready)
        let command = (closeOutput ? "exec 1>&- 2>&-; " : "") + ": > \"$1\"; exec /bin/sleep 600"
        let result = try SystemCommandRunner(now: { clock.now() }).run("/bin/sh",
            ["-c", command, "resh-test", ready.path], timeout: 1)
        #expect(result.status == 124)
    }
    @Test func timeoutStopsChildProcesses() throws {
        let temporary = try TemporaryDirectory(), ready = temporary.url.appendingPathComponent("ready")
        let clock = CommandClock(ready: ready)
        let command = "trap 'wait; exit' TERM; /bin/sleep 600 & echo $! > \"$1.tmp\"; /bin/mv \"$1.tmp\" \"$1\"; wait"
        let result = try SystemCommandRunner(now: { clock.now() }).run("/bin/sh",
            ["-c", command, "resh-test", ready.path], timeout: 1)
        #expect(result.status == 124)
        let pid = try #require(Int32(String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }
}
