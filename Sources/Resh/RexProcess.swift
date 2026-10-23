import Darwin
import Foundation
import ReshCore

/// An owned CLI connection, not a Rex server. Unlike Foundation.Process, this
/// inherits the launchd job's process group, so launchd can terminate old
/// bridges after a host crash. Pipes also tie the Lua scripts to their owner.
final class RexProcess: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [pid_t: RexProcess] = [:]
    private static let queue = DispatchQueue(label: "resh.cli-lifecycle", qos: .utility)

    let pid: pid_t
    let input: FileHandle?
    let output: FileHandle
    private let lock = NSLock()
    private let exited = DispatchGroup()
    private var source: DispatchSourceProcess?
    private var running = true
    private var stopping = false

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    init(executable: String, arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
          pipeInput: Bool = false) throws {
        var descriptors: [Int32] = []
        func pipe() throws -> (Int32, Int32) {
            var pair: [Int32] = [-1, -1]
            guard Darwin.pipe(&pair) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            descriptors += pair
            for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (pair[0], pair[1])
        }
        defer { for fd in descriptors { close(fd) } }
        let stdout = try pipe()
        let stdin = try pipeInput ? pipe() : nil
        let null = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        descriptors.append(null)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, stdin?.0 ?? null, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout.1, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO)
        // No SETPGROUP: launchd owns this group. Only explicitly duplicated fds
        // survive exec; neither the app's flock nor other connections leak in.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var environment = environment
        for key in ["REX_SESSION", "REX_BLOCK", "REX_CLIENT", "REX_SERVER"] { environment.removeValue(forKey: key) }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var identifier: pid_t = 0
        let status = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                posix_spawn(&identifier, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        pid = identifier
        output = FileHandle(fileDescriptor: stdout.0, closeOnDealloc: true)
        input = stdin.map { FileHandle(fileDescriptor: $0.1, closeOnDealloc: true) }
        descriptors.removeAll { $0 == stdout.0 || $0 == stdin?.1 }
        if let input {
            _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
            _ = fcntl(input.fileDescriptor, F_SETFL, fcntl(input.fileDescriptor, F_GETFL) | O_NONBLOCK)
        }
        exited.enter()
        Self.registryLock.lock(); Self.registry[pid] = self; Self.registryLock.unlock()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: Self.queue)
        self.source = source
        source.setEventHandler { [self] in reap() }
        source.resume()
    }

    /// Nonblocking, including when the child ignores SIGTERM. Keep the PID
    /// unreaped until the exit source runs, so escalation cannot hit a reused PID.
    func stop() {
        lock.lock()
        guard running, !stopping else { lock.unlock(); return }
        stopping = true
        _ = kill(pid, SIGTERM)
        lock.unlock()
        Self.queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [self] in
            lock.lock(); defer { lock.unlock() }
            if running { _ = kill(pid, SIGKILL) }
        }
    }

    func waitForExit(timeout: TimeInterval = 1) -> Bool { exited.wait(timeout: .now() + timeout) == .success }

    private func reap() {
        lock.lock()
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        guard result == pid || (result < 0 && errno == ECHILD) else { lock.unlock(); return }
        running = false
        source?.cancel(); source = nil
        lock.unlock()
        Self.registryLock.lock(); Self.registry.removeValue(forKey: pid); Self.registryLock.unlock()
        exited.leave()
    }

    /// Includes children already retiring after a panel close or reconnect.
    static func stopAll() -> [RexProcess] {
        registryLock.lock(); let children = Array(registry.values); registryLock.unlock()
        for child in children { child.stop() }
        return children
    }
}
