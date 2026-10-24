import Foundation

/// Process-owned successful selections, shared by every client-facing service.
final class SessionHistory: @unchecked Sendable {
    struct Visit: Sendable {
        let clientID: String
        let server: String
        let sessionID: String
        let host: RexHost?

        var candidateID: String { Candidate.identity(sessionID, host: host) }
        func belongs(to clientID: String, server: String) -> Bool {
            self.clientID == clientID && self.server == server
        }
    }

    private let lock = NSLock()
    private var visits: [Visit] = []

    /// Keep a switch and its history update ordered across client handles.
    func withVisits<T>(_ operation: (inout [Visit]) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation(&visits)
    }

    static func record(_ sessionID: String, host: RexHost?, clientID: String, server: String, visits: inout [Visit]) {
        let visit = Visit(clientID: clientID, server: server, sessionID: sessionID, host: host)
        visits.removeAll {
            $0.belongs(to: clientID, server: server) && $0.candidateID == visit.candidateID
        }
        visits.insert(visit, at: 0)
    }
}
