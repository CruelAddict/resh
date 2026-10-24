import Darwin
import Foundation

/// The kernel releases the lock even if the helper crashes. Never use labels as identity.
public final class FileLock {
    private let descriptor: Int32
    public init(url: URL, wait: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ReshError("Cannot open resh's session lock.") }
        guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
            close(descriptor); throw ReshError("Cannot lock resh's session registry.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

public struct SessionRecord: Codable, Sendable {
    public let server: String
    public let path: String
    public let sessionID: String
    public init(server: String, path: String, sessionID: String) {
        self.server = server; self.path = path; self.sessionID = sessionID
    }
}

public struct SessionRegistry: Sendable {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("sessions.json") }
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/resh")) { self.directory = directory }

    public func load() throws -> [SessionRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([SessionRecord].self, from: Data(contentsOf: url)) }
        catch { throw ReshError("resh's session registry is unreadable: \(url.path).") }
    }
    public func save(_ records: [SessionRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
