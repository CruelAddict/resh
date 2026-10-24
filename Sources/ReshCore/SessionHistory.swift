import Foundation

/// Successful resh selections only. Rex's attachment list is not a focus history.
struct SessionHistory: Sendable {
    struct Visit: Codable, Sendable {
        let clientID: String
        let server: String
        let sessionID: String
        let host: RexHost?

        var candidateID: String { Candidate.identity(sessionID, host: host) }
        func belongs(to clientID: String, server: String) -> Bool {
            self.clientID == clientID && self.server == server
        }
    }

    let directory: URL
    var lockURL: URL { directory.appendingPathComponent("history.lock") }
    private var url: URL { directory.appendingPathComponent("history.json") }

    func load() throws -> [Visit] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([Visit].self, from: Data(contentsOf: url)) }
        catch { throw ReshError("resh's session history is unreadable: \(url.path).") }
    }

    func record(_ sessionID: String, host: RexHost?, clientID: String, server: String, visits: [Visit]) throws {
        let visit = Visit(clientID: clientID, server: server, sessionID: sessionID, host: host)
        var updated = visits.filter {
            !$0.belongs(to: clientID, server: server) || $0.candidateID != visit.candidateID
        }
        updated.insert(visit, at: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try JSONEncoder().encode(updated).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ReshError("Switched Rex to the session, but could not save resh's history: \(url.path).\n\(error.localizedDescription)")
        }
    }
}
