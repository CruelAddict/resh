import Foundation

/// Program status and pane titles cross the bridge; terminal output is never read.
public struct RexAttentionRecord: Codable, Equatable, Sendable {
    public let sessionID: String
    public let blockID: String
    public let recordID: String?
    public let state: String
    public let updatedAt: String
    public let app: String?
    public let title: String?
    public let terminalTitle: String?
    public let windowID: String?
    public let windowIndex: Int?
    public let paneIndex: Int?

    public init(sessionID: String, blockID: String, recordID: String? = nil, state: String, updatedAt: String,
                app: String? = nil, title: String? = nil, terminalTitle: String? = nil, windowID: String? = nil,
                windowIndex: Int? = nil, paneIndex: Int? = nil) {
        self.sessionID = sessionID; self.blockID = blockID; self.recordID = recordID
        self.state = state; self.updatedAt = updatedAt
        self.app = app; self.title = title; self.terminalTitle = terminalTitle; self.windowID = windowID
        self.windowIndex = windowIndex; self.paneIndex = paneIndex
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", blockID = "block_id", recordID = "record_id", state, updatedAt = "updated_at"
        case app, title, terminalTitle = "terminal_title", windowID = "window_id"
        case windowIndex = "window_index", paneIndex = "pane_index"
    }
}

public struct RexAttention: Sendable {
    private struct Identity: Hashable, Sendable {
        let block: String
        let record: String
    }

    private struct Task: Hashable, Sendable {
        let app: String
        let id: String
        let title: String
    }

    private var records: [RexAttentionRecord] = []
    private var tasks: [Identity: Set<Task>] = [:]

    public init() {}

    public mutating func update(_ records: [RexAttentionRecord]) {
        let previous = Dictionary(self.records.map { (Self.identity($0), $0) }, uniquingKeysWith: { _, last in last })
        let panes = Dictionary(grouping: records, by: \.blockID)
        var updated: [Identity: Set<Task>] = [:]
        for record in records {
            let identity = Self.identity(record)
            if let id = record.recordID, let app = record.app, let title = record.title, !title.isEmpty {
                updated[identity] = [Task(app: app, id: id, title: title)]
            } else if record.recordID == nil {
                let children = (panes[record.blockID] ?? []).filter {
                    $0.recordID != nil && $0.app == record.app && (record.title == nil || $0.title == record.title)
                }
                let sources = Set(children.compactMap { child -> Task? in
                    guard let app = child.app, let id = child.recordID, let title = child.title, !title.isEmpty else { return nil }
                    return Task(app: app, id: id, title: title)
                })
                if !sources.isEmpty { updated[identity] = sources }
            }
            if updated[identity] == nil, let old = previous[identity], old.app == record.app,
               record.title == nil || record.title == old.title {
                // Aggregators often clear child reports before returning the
                // root to idle. Retain task provenance, not unread state.
                updated[identity] = tasks[identity]
            }
        }
        self.records = records
        tasks = updated
    }

    public var workingBlockIDs: Set<String> {
        Set(scopedRecords().filter { $0.state == "working" }.map(\.blockID))
    }

    public func unseenRecords(preferences: [String: Any]) throws -> [RexAttentionRecord] {
        try Self.unseenRecords(in: scopedRecords(), preferences: preferences)
    }

    private func scopedRecords() -> [RexAttentionRecord] {
        var owners: [Task: Set<String>] = [:]
        for record in records {
            guard let title = record.terminalTitle else { continue }
            for task in tasks[Self.identity(record)] ?? [] where title == task.title
                || title.hasSuffix(" | " + task.title) || title.hasPrefix(task.title + " | ") {
                owners[task, default: []].insert(record.blockID)
            }
        }
        return records.filter { record in
            guard let sources = tasks[Self.identity(record)], !sources.isEmpty else { return true }
            // IDs are terminal-local. Suppress a mirrored report only when the
            // same app, ID and title identify a task displayed in another pane.
            return sources.contains { task in
                guard let panes = owners[task], !panes.isEmpty else { return true }
                return panes.contains(record.blockID)
            }
        }
    }

    private static func identity(_ record: RexAttentionRecord) -> Identity {
        Identity(block: record.blockID, record: record.recordID ?? "")
    }

    /// Rex's read receipts are client-side, not part of the server API. Like theme
    /// preferences, this is a read-only integration, never our own unread ledger.
    public static func unseenSessionIDs(in records: [RexAttentionRecord], preferences: [String: Any]) throws -> Set<String> {
        Set(try unseenRecords(in: records, preferences: preferences).map(\.sessionID))
    }

    public static func unseenRecords(in records: [RexAttentionRecord], preferences: [String: Any]) throws -> [RexAttentionRecord] {
        let records = records.filter { ["done", "blocked", "error", "idle"].contains($0.state) }
        guard !records.isEmpty else { return [] }
        guard let ledger = preferences["Workspace.programActivitySeen"] as? [String: Any] else {
            throw ReshError("Rex read receipts are unavailable; unread indicators cannot be determined.")
        }
        func dates(_ key: String) throws -> [Identity: Set<Int64>] {
            var result: [Identity: Set<Int64>] = [:]
            guard let value = ledger[key] else { return result }
            guard let receipts = value as? [[String: Any]] else { throw ReshError("Unsupported Rex read-receipt format.") }
            for receipt in receipts {
                guard let block = receipt["block"] as? String, let record = receipt["record"] as? String,
                      let date = receipt["date"] as? Date else { throw ReshError("Invalid Rex read receipt.") }
                result[Identity(block: block, record: record), default: []].insert(milliseconds(date))
            }
            return result
        }
        let seen = try dates("receipts"), alerted = try dates("alerted")
        return try records.filter { record in
            let identity = Identity(block: record.blockID, record: record.recordID ?? "")
            let date = try milliseconds(timestamp(record.updatedAt))
            // Rex also announces completion when an agent returns to idle. Only
            // accept idle when Rex actually recorded an alert for that report;
            // a shell/agent simply resting is not a notification.
            let announcedIdle = record.state == "idle" && alerted[identity]?.contains(date) == true
            guard ["done", "blocked", "error"].contains(record.state) || announcedIdle else { return false }
            return seen[identity]?.contains(date) != true
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        // Rex parses protocol timestamps at millisecond precision, while the
        // server returns micro/nanoseconds. Match its receipt identity, not a
        // microsecond-exact Date that can never equal the stored receipt.
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func timestamp(_ value: String) throws -> Date {
        // ISO8601DateFormatter is deliberately millisecond-based, like Rex's
        // ledger. Parse before rounding so .923999 does not become .924.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw ReshError("Invalid Rex activity timestamp: \(value)") }
        return date
    }
}
