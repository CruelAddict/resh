import Foundation

/// One row per terminal, including its child reports, regardless of the program's name.
public struct RexAgent: Sendable {
    public let candidate: Candidate
    public let isWorking: Bool

    public static func identity(sessionID: String, blockID: String, host: RexHost? = nil) -> String {
        Candidate.identity("agent:" + sessionID + "/" + blockID, host: host)
    }

    public static func panes(in records: [RexAttentionRecord], session: Candidate, workingBlockIDs: Set<String>? = nil) -> [Self] {
        let blocks = Dictionary(grouping: records.filter { $0.sessionID == session.sessionID }, by: \.blockID)
        let ordered = blocks.keys.sorted {
            let a = blocks[$0]!.first!, b = blocks[$1]!.first!
            return (a.windowIndex ?? Int.max, a.paneIndex ?? Int.max, $0)
                < (b.windowIndex ?? Int.max, b.paneIndex ?? Int.max, $1)
        }
        return ordered.compactMap { blockID in
            let reports = blocks[blockID]!
            let named = reports.filter { $0.app?.isEmpty == false }
            guard let report = named.first(where: { $0.recordID == nil }) ?? named.first,
                  let app = report.app, let sessionID = session.sessionID else { return nil }
            let label: String
            switch app.lowercased() {
            case "opencode": label = "OC"
            case "claude-code", "claude": label = "Claude"
            case "codex": label = "Codex"
            default: label = app
            }
            // The pane title describes what the user will actually see on opening it.
            // A root report can be an aggregate of several background tasks.
            var title = report.terminalTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? report.title ?? named.compactMap(\.title).first ?? app
            for prefix in [label + " | ", app + " | "] where title.hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
                break
            }
            let candidate = Candidate(id: identity(sessionID: sessionID, blockID: blockID, host: session.host),
                kind: .agent, title: session.title + " / " + label + " | " + title,
                sessionID: sessionID, host: session.host, blockID: blockID, windowID: report.windowID,
                agent: Candidate.Agent(app: app, sessionTitle: session.title, title: title))
            return Self(candidate: candidate, isWorking: workingBlockIDs?.contains(blockID) ?? reports.contains { $0.state == "working" })
        }
    }
}
