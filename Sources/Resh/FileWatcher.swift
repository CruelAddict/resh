import Darwin
import Foundation

/// Watches both the file and its directory, including atomic saves and files
/// whose parent directory does not exist yet. Unrelated directory writes are ignored.
final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "resh.files", qos: .utility)
    private let ready = DispatchGroup()
    private var sources: [String: Watch] = [:]
    private var retiring: [DispatchSourceFileSystemObject] = []
    private var registering = Set<UUID>()
    private var signature: Signature?
    private var stopped = false

    private struct Watch {
        let source: DispatchSourceFileSystemObject
        let device: dev_t
        let inode: ino_t
    }

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

    deinit {
        for watch in sources.values { watch.source.cancel() }
        for source in retiring { source.cancel() }
        for _ in registering { ready.leave() }
    }

    /// Call off the UI thread before the initial read, so it cannot precede the watch.
    func waitUntilReady() { ready.wait() }

    func stop() {
        ready.enter()
        queue.async { [self] in
            stopped = true
            for watch in sources.values { watch.source.cancel() }
            for source in retiring { source.cancel() }
            sources = [:]; retiring = []
            for _ in registering { ready.leave() }
            registering = []
            ready.leave()
        }
    }

    private func readSignature() -> Signature? {
        var value = stat()
        guard stat(url.path, &value) == 0 else { return nil }
        return Signature(inode: value.st_ino, size: value.st_size,
            seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec)
    }

    private func watch() {
        guard !stopped else { return }
        var paths = Set<String>()
        var files = [url, url.resolvingSymlinksInPath()]
        // Foundation may leave a dangling symlink unresolved. Keep watching its
        // target's parent so recreating the target is observable too.
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            files.append(URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent()).standardizedFileURL)
        }
        for file in files {
            paths.insert(file.path)
            var parent = file.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
                parent.deleteLastPathComponent()
            }
            paths.insert(parent.path)
        }
        for (path, watch) in sources {
            var value = stat()
            if !paths.contains(path) || stat(path, &value) != 0
                || value.st_dev != watch.device || value.st_ino != watch.inode {
                sources.removeValue(forKey: path)
                retiring.append(watch.source)
            }
        }
        for path in paths where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { close(descriptor); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend, .revoke], queue: queue)
            let registration = UUID()
            registering.insert(registration)
            ready.enter()
            source.setRegistrationHandler { [weak self] in
                guard let self, registering.remove(registration) != nil else { return }
                // Reconcile changes made before registration, without opening a
                // gap in the still-active parent-directory watch.
                watch()
                ready.leave()
            }
            source.setCancelHandler { close(descriptor) }
            source.setEventHandler { [weak self] in self?.watch() }
            sources[path] = Watch(source: source, device: value.st_dev, inode: value.st_ino)
            source.resume()
        }
        // Keep old observations until their replacements can receive events.
        if registering.isEmpty {
            for source in retiring { source.cancel() }
            retiring = []
        }
        let updated = readSignature()
        if updated != signature { signature = updated; onChange() }
    }
}
