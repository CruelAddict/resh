import Foundation

/// Shared MRU order. Runtime timestamps protect confirmed selections from queued observations.
final class SessionHistory: @unchecked Sendable {
    struct Visit: Sendable {
        let sessionID: String
        let selectedAt: ContinuousClock.Instant?
    }

    private struct Document: Codable {
        var version = 1
        let sessions: [String]
    }

    private let lock = NSLock()
    let url: URL?
    private var visits: [Visit] = []
    private var loaded = false
    private var dirty = false
    private var writable = true
    private var persistenceError: String?

    init(url: URL?) { self.url = url }

    var error: String? {
        lock.lock(); defer { lock.unlock() }
        load()
        return persistenceError
    }

    /// Keep a switch and its history update ordered across client handles.
    func withVisits<T>(_ operation: (inout [Visit]) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        load()
        let previous = visits.map(\.sessionID)
        defer {
            if visits.map(\.sessionID) != previous { dirty = true }
            if dirty { save() }
        }
        return try operation(&visits)
    }

    static func record(_ sessionID: String, from current: String? = nil,
                        at selectedAt: ContinuousClock.Instant = .now, visits: inout [Visit]) {
        // Queued observations must not undo a later observation or successful command.
        if let latest = visits.first?.selectedAt, latest > selectedAt { return }
        if let current, current != sessionID {
            record(current, at: selectedAt, visits: &visits)
        }
        visits.removeAll { $0.sessionID == sessionID }
        visits.insert(Visit(sessionID: sessionID, selectedAt: selectedAt), at: 0)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else {
                writable = false
                throw ReshError("Unsupported resh history version: \(document.version).")
            }
            var seen = Set<String>()
            visits = document.sessions.filter { !$0.isEmpty && seen.insert($0).inserted }
                .map { Visit(sessionID: $0, selectedAt: nil) }
        } catch {
            let message = "Cannot read resh history at \(url.path): \(error.localizedDescription)"
            persistenceError = message
            DebugLog.shared.record(message, source: "history")
            guard writable else { return }
            // Preserve damaged input before accepting new visits.
            do {
                let backup = url.deletingLastPathComponent().appendingPathComponent("history.corrupt-\(UUID().uuidString).json")
                try FileManager.default.moveItem(at: url, to: backup)
            } catch { writable = false }
        }
    }

    private func save() {
        guard let url, writable else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Document(sessions: visits.map(\.sessionID))).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            dirty = false
            persistenceError = nil
        } catch {
            let message = "Cannot save resh history at \(url.path): \(error.localizedDescription)"
            if message != persistenceError { DebugLog.shared.record(message, source: "history") }
            persistenceError = message
        }
    }
}
