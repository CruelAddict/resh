import Foundation
import ReshCore
import Testing

@Suite("Rex session attention")
struct AttentionTests {
    private let time = "2026-10-22T20:59:59.092024+03:00"

    private func record(_ state: String = "done", session: String = "s", block: String = "b",
                        id: String? = nil, time: String? = nil) -> RexAttentionRecord {
        RexAttentionRecord(sessionID: session, blockID: block, recordID: id, state: state, updatedAt: time ?? self.time)
    }

    private func preferences(block: String = "b", id: String = "", time: String? = nil) throws -> [String: Any] {
        let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time ?? self.time)
        return ["Workspace.programActivitySeen": ["receipts": [["block": block, "record": id, "date": date]]]]
    }

    @Test(arguments: ["done", "blocked", "error", "working", "idle", "clear", "future-state"])
    func onlyUnseenAttentionStatesShowDots(_ state: String) throws {
        let result = try RexAttention.unseenSessionIDs(in: [record(state)], preferences: ["Workspace.programActivitySeen": [:]])
        #expect(result == (["done", "blocked", "error"].contains(state) ? ["s"] : []))
    }

    @Test func usesRexReadReceiptsWithSubsecondAndTimezonePrecision() throws {
        let preferences = try preferences(time: "2026-10-22T17:59:59.092024Z")
        #expect(try RexAttention.unseenSessionIDs(in: [record()], preferences: preferences).isEmpty)
        // Seeing an earlier update must not hide a later result in the same terminal.
        let later = record(time: "2026-10-22T20:59:59.093024+03:00")
        #expect(try RexAttention.unseenSessionIDs(in: [later], preferences: preferences) == ["s"])
    }

    @Test func receiptsMatchBlockRecordAndTimestampNotJustSession() throws {
        let preferences = try preferences()
        #expect(try RexAttention.unseenSessionIDs(in: [record(block: "other")], preferences: preferences) == ["s"])
        #expect(try RexAttention.unseenSessionIDs(in: [record(id: "child")], preferences: preferences) == ["s"])
        #expect(try RexAttention.unseenSessionIDs(in: [record(id: "child")],
            preferences: try self.preferences(id: "child")).isEmpty)
    }

    @Test func aggregatesAllPanesAndChildRecordsWithoutLettingWorkingMaskAttention() throws {
        let records = [record(), record("working"), record("blocked", block: "second", id: "worker"),
            record("error", session: "another", block: "third"), record("idle", session: "quiet")]
        #expect(try RexAttention.unseenSessionIDs(in: records, preferences: preferences()) == ["s", "another"])
    }

    @Test func missingOrChangedPrivatePreferencesReportAnError() throws {
        for preferences: [String: Any] in [[:], ["Workspace.programActivitySeen": "new-format"],
            ["Workspace.programActivitySeen": ["receipts": [["date": "not-a-date"]]]]] {
            #expect(throws: ReshError.self) { try RexAttention.unseenSessionIDs(in: [record()], preferences: preferences) }
        }
        #expect(try RexAttention.unseenSessionIDs(in: [], preferences: [:]).isEmpty)
    }

    @Test func alertedIsNotAReadReceipt() throws {
        let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time)
        let preferences: [String: Any] = ["Workspace.programActivitySeen": [
            "alerted": [["block": "b", "record": "", "date": date]]]]
        #expect(try RexAttention.unseenSessionIDs(in: [record()], preferences: preferences) == ["s"])
    }

    @Test func nativeAnnouncedIdleIsACompletedUnreadTaskNotPlainIdle() throws {
        let idle = record("idle", time: "2026-10-22T21:21:56.923423+03:00")
        let nativeDate = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-10-22T18:21:56.923Z")
        let nativeReceipt: [String: Any] = ["block": "b", "record": "", "date": nativeDate]
        let unread: [String: Any] = ["Workspace.programActivitySeen": ["alerted": [nativeReceipt]]]
        #expect(try RexAttention.unseenSessionIDs(in: [idle], preferences: unread) == ["s"])
        let read: [String: Any] = ["Workspace.programActivitySeen": [
            "alerted": [nativeReceipt], "receipts": [nativeReceipt]]]
        #expect(try RexAttention.unseenSessionIDs(in: [idle], preferences: read).isEmpty)
        #expect(try RexAttention.unseenSessionIDs(in: [idle], preferences: ["Workspace.programActivitySeen": [:]]).isEmpty)
        #expect(try RexAttention.unseenSessionIDs(in: [record("working", time: idle.updatedAt)], preferences: unread).isEmpty)
        #expect(try RexAttention.unseenSessionIDs(in: [record("idle", id: "other", time: idle.updatedAt)], preferences: unread).isEmpty)
        #expect(try RexAttention.unseenSessionIDs(in: [record("idle", time: "2026-10-22T18:21:56.924Z")], preferences: unread).isEmpty)
    }

    @Test func nativeReadReceiptsUseMillisecondsNotProtocolMicroseconds() throws {
        let preferences = try preferences(time: "2026-10-22T17:59:59.092Z")
        #expect(try RexAttention.unseenSessionIDs(in: [record()], preferences: preferences).isEmpty)
        #expect(try RexAttention.unseenSessionIDs(in: [record(time: "2026-10-22T17:59:59.092999Z")],
            preferences: preferences).isEmpty)
        #expect(try RexAttention.unseenSessionIDs(in: [record(time: "2026-10-22T17:59:59.093024Z")],
            preferences: preferences) == ["s"])
    }

    @Test func unknownFieldsAndRootRecordsDecode() throws {
        let json = """
        {"session_id":"s","block_id":"b","state":"done","updated_at":"2026-10-22T17:59:59Z","future":true}
        """
        let decoded = try JSONDecoder().decode(RexAttentionRecord.self, from: Data(json.utf8))
        #expect(decoded.recordID == nil)
        let date = try Date.ISO8601FormatStyle().parse("2026-10-22T17:59:59Z")
        #expect(try RexAttention.unseenSessionIDs(in: [decoded], preferences: ["Workspace.programActivitySeen": [
            "receipts": [["block": "b", "record": "", "date": date]]]]).isEmpty)
    }
}
