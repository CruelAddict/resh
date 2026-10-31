import Darwin
import Foundation
import ReshCore
import Testing

@Suite("Subprocess execution", .serialized)
struct RunnerTests {
    @Test(arguments: ["--source", "--config", "--repository", "--version"])
    func missingInstallationOptionValue(_ option: String) throws {
        let installer = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh")
        let result = try SystemCommandRunner().run("/bin/bash", [installer.path, option], timeout: 2)
        #expect(result.status != 0)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("Missing value for \(option)"))
    }

    @Test(arguments: [["--repository", "owner/repo"], ["--verify"]])
    func conflictingInstallationSources(_ options: [String]) throws {
        let installer = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh")
        let result = try SystemCommandRunner().run("/bin/bash", [installer.path, "--source", "distribution"] + options, timeout: 2)
        #expect(result.status != 0)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("--source cannot be combined"))
    }

    @Test func drainsBothPipes() throws {
        let result = try SystemCommandRunner().run("/usr/bin/python3",
            ["-c", "import sys; sys.stdout.write('o'*200000); sys.stderr.write('e'*200000)"], timeout: 10)
        #expect(result.status == 0 && result.stdout.count == 200_000 && result.stderr.count == 200_000)
    }
    @Test func reportsFailureAndCapsOutput() throws {
        let runner = SystemCommandRunner()
        #expect(try runner.run("/usr/bin/false", [], timeout: 1).status == 1)
        #expect(throws: ReshError.self) { try runner.run("/usr/bin/yes", [], timeout: 3) }
    }
    @Test(arguments: ["sleep 10", "exec 1>&- 2>&-; sleep 10"])
    func timeoutCoversTheEntireProcess(_ command: String) throws {
        let started = ProcessInfo.processInfo.systemUptime
        #expect(try SystemCommandRunner().run("/bin/sh", ["-c", command], timeout: 0.03).status == 124)
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
    }
    @Test func timeoutStopsChildProcesses() throws {
        let result = try SystemCommandRunner().run("/bin/sh", ["-c", "trap 'wait; exit' TERM; sleep 10 & echo $!; wait"], timeout: 0.1)
        #expect(result.status == 124)
        let pid = try #require(Int32(result.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }
}
