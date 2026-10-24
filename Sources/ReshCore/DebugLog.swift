import Darwin
import Foundation

/// Opt-in diagnostics shared by the CLI and resident panel, never a UI channel.
public final class DebugLog: @unchecked Sendable {
    public static let shared = DebugLog()
    public let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/resh/debug.log")
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    private init() {}
    deinit { if descriptor >= 0 { close(descriptor) } }

    public func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !enabled {
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
            return
        }
        guard descriptor < 0 else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        } catch {
            FileHandle.standardError.write(Data(("resh: Cannot open debug log: \(error.localizedDescription)\n").utf8))
        }
    }

    public func record(_ error: Error, source: String) {
        record(error.localizedDescription, source: source)
    }

    public func record(_ message: @autoclosure () -> String, source: String) {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        let entry = ["time": Date().ISO8601Format(), "source": source, "message": String(message().prefix(8192))]
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(10)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                offset += count
            }
        }
    }
}
