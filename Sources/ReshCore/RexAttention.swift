import Foundation

/// Only identity and status cross the bridge; terminal messages are not needed by the picker.
public struct RexAttentionRecord: Codable, Equatable, Sendable {
    public let sessionID: String
    public let blockID: String
    public let recordID: String?
    public let state: String
    public let updatedAt: String

    public init(sessionID: String, blockID: String, recordID: String? = nil, state: String, updatedAt: String) {
        self.sessionID = sessionID; self.blockID = blockID; self.recordID = recordID
        self.state = state; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", blockID = "block_id", recordID = "record_id", state, updatedAt = "updated_at"
    }
}

public enum RexAttention {
    private struct Identity: Hashable {
        let block: String
        let record: String
    }

    /// Rex's read receipts are client-side, not part of the server API. Like theme
    /// preferences, this is a read-only integration, never our own unread ledger.
    public static func unseenSessionIDs(in records: [RexAttentionRecord], preferences: [String: Any]) throws -> Set<String> {
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
        return try Set(records.compactMap { record in
            let identity = Identity(block: record.blockID, record: record.recordID ?? "")
            let date = try milliseconds(timestamp(record.updatedAt))
            // Rex also announces completion when an agent returns to idle. Only
            // accept idle when Rex actually recorded an alert for that report;
            // a shell/agent simply resting is not a notification.
            let announcedIdle = record.state == "idle" && alerted[identity]?.contains(date) == true
            guard ["done", "blocked", "error"].contains(record.state) || announcedIdle else { return nil }
            if seen[identity]?.contains(date) == true { return nil }
            return record.sessionID
        })
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
