import Darwin
import Foundation

/// Watches both the file and its directory, including atomic saves and files
/// whose parent directory does not exist yet. Unrelated directory writes are ignored.
final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "resh.files", qos: .utility)
    private let ready = DispatchGroup()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var signature: Signature?
    private var stopped = false

    private struct Signature: Equatable {
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
    }

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url; self.onChange = onChange
        ready.enter()
        queue.async { [self] in signature = readSignature(); watch(); ready.leave() }
    }

    deinit { for source in sources { source.cancel() } }

    /// Call off the UI thread before the initial read, so it cannot precede the watch.
    func waitUntilReady() { ready.wait() }

    func stop() {
        queue.async { [self] in
            stopped = true
            for source in sources { source.cancel() }
            sources = []
        }
    }

    private func readSignature() -> Signature? {
        var value = stat()
        guard stat(url.path, &value) == 0 else { return nil }
        return Signature(inode: value.st_ino, size: value.st_size,
            seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec)
    }

    private func watch() {
        for source in sources { source.cancel() }
        sources = []
        var parent = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            parent.deleteLastPathComponent()
        }
        for path in Set([url.path, url.resolvingSymlinksInPath().path, parent.path]) {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend, .revoke], queue: queue)
            source.setCancelHandler { close(descriptor) }
            source.setEventHandler { [weak self] in
                guard let self, !stopped else { return }
                let updated = readSignature()
                if updated != signature { signature = updated; onChange() }
                watch()
            }
            sources.append(source)
            source.resume()
        }
    }
}
