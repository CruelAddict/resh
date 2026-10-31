import Darwin
import Foundation

/// File and parent-directory observations survive atomic replacement and recreation.
final class FileWatcher: @unchecked Sendable {
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

    private let url: URL
    private let onChange: @Sendable () -> Void
    private let onError: @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "resh.rex-focus.files", qos: .utility)
    private var sources: [String: Watch] = [:]
    private var retiring: [DispatchSourceFileSystemObject] = []
    private var registering = Set<UUID>()
    private var signature: Signature?
    private var stopped = false

    init(url: URL, onChange: @escaping @Sendable () -> Void, onError: @escaping @Sendable (Error) -> Void) {
        self.url = url; self.onChange = onChange; self.onError = onError
        queue.async { [self] in
            signature = readSignature()
            watch()
            onChange()
        }
    }

    deinit {
        for watch in sources.values { watch.source.cancel() }
        for source in retiring { source.cancel() }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            for watch in sources.values { watch.source.cancel() }
            for source in retiring { source.cancel() }
            sources = [:]; retiring = []; registering = []
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
        let file = url.resolvingSymlinksInPath()
        var paths: Set<String> = [url.path, file.path]
        for target in [url, file] {
            var parent = target.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
                parent.deleteLastPathComponent()
            }
            paths.insert(parent.path)
        }
        for (path, watch) in sources {
            var value = stat()
            if !paths.contains(path) || stat(path, &value) != 0 || value.st_dev != watch.device || value.st_ino != watch.inode {
                sources.removeValue(forKey: path)
                retiring.append(watch.source)
            }
        }
        for path in paths where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno != ENOENT { onError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
                continue
            }
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { close(descriptor); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend, .revoke], queue: queue)
            let registration = UUID()
            registering.insert(registration)
            source.setRegistrationHandler { [weak self] in
                guard let self, registering.remove(registration) != nil else { return }
                watch()
            }
            source.setCancelHandler { close(descriptor) }
            source.setEventHandler { [weak self] in self?.watch() }
            sources[path] = Watch(source: source, device: value.st_dev, inode: value.st_ino)
            source.resume()
        }
        // Retain replaced observations until their replacements are registered.
        if registering.isEmpty {
            for source in retiring { source.cancel() }
            retiring = []
        }
        let updated = readSignature()
        if updated != signature { signature = updated; onChange() }
    }
}
