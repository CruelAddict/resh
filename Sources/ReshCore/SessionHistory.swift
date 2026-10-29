import Foundation

/// Process-owned confirmed selections and observed visits, shared by every client-facing service.
final class SessionHistory: @unchecked Sendable {
    struct Visit: Sendable {
        let clientID: String
        let server: String
        let sessionID: String
        let host: RexHost?
        let selectedAt: ContinuousClock.Instant

        var candidateID: String { Candidate.identity(sessionID, host: host) }
        func belongs(to clientID: String, server: String) -> Bool {
            self.clientID == clientID && self.server == server
        }
        func matches(_ sessionID: String, host: RexHost?) -> Bool {
            guard self.sessionID == sessionID else { return false }
            if self.host?.id == host?.id { return true }
            guard let saved = self.host, let host else { return false }
            return !Set(saved.endpoints).isDisjoint(with: host.endpoints)
        }
    }

    private let lock = NSLock()
    private var visits: [Visit] = []

    /// Keep a switch and its history update ordered across client handles.
    func withVisits<T>(_ operation: (inout [Visit]) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation(&visits)
    }

    static func record(_ sessionID: String, host: RexHost?, clientID: String, server: String, from current: Candidate? = nil,
                       at selectedAt: ContinuousClock.Instant = .now, visits: inout [Visit]) {
        // Queued observations must not undo a later observation or successful command.
        if let latest = visits.first(where: { $0.belongs(to: clientID, server: server) }), latest.selectedAt > selectedAt { return }
        let visit = Visit(clientID: clientID, server: server, sessionID: sessionID, host: host, selectedAt: selectedAt)
        if let current, let sourceID = current.sessionID, !visit.matches(sourceID, host: current.host) {
            record(sourceID, host: current.host, clientID: clientID, server: server, at: selectedAt, visits: &visits)
        }
        visits.removeAll {
            $0.belongs(to: clientID, server: server) && $0.matches(sessionID, host: host)
        }
        visits.insert(visit, at: 0)
    }
}
