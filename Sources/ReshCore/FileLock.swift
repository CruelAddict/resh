import Darwin
import Foundation

/// The kernel releases the lock even if the helper crashes.
public final class FileLock {
    private let descriptor: Int32
    public init(url: URL, wait: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ReshError("Cannot open resh's lock.") }
        guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
            close(descriptor); throw ReshError("Cannot acquire resh's lock.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
