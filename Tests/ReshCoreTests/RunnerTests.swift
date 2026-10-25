import Darwin
import Foundation
import ReshCore
import Testing

@Suite("Subprocess execution")
struct RunnerTests {
    @Test(arguments: [[], ["--remote"]])
    func missingInstallationOptionValue(_ options: [String]) throws {
        let installer = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh")
        let result = try SystemCommandRunner().run("/bin/bash", [installer.path] + options + ["--source"], timeout: 2)
        #expect(result.status != 0)
        #expect(String(decoding: result.stderr, as: UTF8.self).contains("Missing value for --source"))
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
    @Test func cancellationStopsTheProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resh-runner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        try #require(mkfifo(ready.path, 0o600) == 0)
        let descriptor = open(ready.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let task = Task.detached {
            try SystemCommandRunner().run("/bin/sh", ["-c", "echo $$ > \"$1\"; exec /bin/sleep 10", "sh", ready.path], timeout: 20)
        }
        // The runner blocks a cooperative worker; acknowledge and cancel from GCD.
        let cancellation: (pid: pid_t?, started: TimeInterval) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                var bytes = [UInt8](repeating: 0, count: 64)
                let count = Darwin.poll(&event, 1, 1000) > 0 ? Darwin.read(descriptor, &bytes, bytes.count) : 0
                let pid = Int32(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                let alive = pid > 0 && kill(pid, 0) == 0
                let started = ProcessInfo.processInfo.systemUptime
                task.cancel()
                continuation.resume(returning: (alive ? pid : nil, started))
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ProcessInfo.processInfo.systemUptime - cancellation.started < 1)
        let pid = try #require(cancellation.pid, "Command did not acknowledge a live process.")
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
    @Test func timeoutStopsChildProcesses() throws {
        let result = try SystemCommandRunner().run("/bin/sh", ["-c", "trap 'wait; exit' TERM; sleep 10 & echo $!; wait"], timeout: 0.1)
        #expect(result.status == 124)
        let pid = try #require(Int32(result.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0)
    }
}
