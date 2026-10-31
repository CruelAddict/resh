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

    @Test func mirroredTaskLifecycle() throws {
        var attention = RexAttention()
        let working = ["task", "other"].flatMap { block in
            [nil, "worker"].map { id in
                RexAttentionRecord(sessionID: block, blockID: block, recordID: id, state: "working", updatedAt: time,
                    app: "builder", title: "Build", terminalTitle: block == "task" ? "Harness | Build" : "Harness | Notes")
            }
        }
        attention.update(working)
        #expect(attention.workingBlockIDs == ["task"])
        attention.update(working.filter { $0.recordID == nil })
        #expect(attention.workingBlockIDs == ["task"])
        let completed = working.filter { $0.recordID == nil }.map {
            RexAttentionRecord(sessionID: $0.sessionID, blockID: $0.blockID, state: "idle", updatedAt: time,
                app: $0.app, terminalTitle: $0.terminalTitle)
        }
        attention.update(completed)
        #expect(attention.workingBlockIDs.isEmpty)
        let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(time)
        let alerted = completed.map { ["block": $0.blockID, "record": "", "date": date] as [String: Any] }
        let unread = ["Workspace.programActivitySeen": ["alerted": alerted]]
        #expect(try attention.unseenRecords(preferences: unread).map(\.blockID) == ["task"])
        let read = ["Workspace.programActivitySeen": ["alerted": alerted, "receipts": [alerted[0]]]]
        #expect(try attention.unseenRecords(preferences: read).isEmpty)

        // A newly attached observer has no evidence about the completed task.
        var attached = RexAttention()
        attached.update(completed)
        #expect(try attached.unseenRecords(preferences: unread).count == 2)
    }

    @Test(arguments: ["done", "blocked", "error"])
    func mirroredTaskReports(_ state: String) throws {
        var attention = RexAttention()
        let reports = ["task", "other"].flatMap { block in
            [nil, "worker"].map { id in
                RexAttentionRecord(sessionID: block, blockID: block, recordID: id, state: state, updatedAt: time,
                    app: "another-agent", title: "Review", terminalTitle: block == "task" ? "Review | Project" : "Notes")
            }
        }
        attention.update(reports)
        let unseen = try attention.unseenRecords(preferences: ["Workspace.programActivitySeen": [:]])
        #expect(Set(unseen.map(\.blockID)) == ["task"])
        #expect(unseen.count == 2)
    }

    @Test(arguments: ["Build", "Notes"], ["working", "blocked"])
    func backgroundTaskReports(_ paneTitle: String, state: String) throws {
        var attention = RexAttention()
        let reports = ["first", "second"].map { block in
            RexAttentionRecord(sessionID: block, blockID: block, recordID: "build", state: state, updatedAt: time,
                app: "builder", title: "Build", terminalTitle: paneTitle)
        }
        attention.update(reports)
        #expect(attention.workingBlockIDs == (state == "working" ? ["first", "second"] : []))
        #expect(try attention.unseenRecords(preferences: ["Workspace.programActivitySeen": [:]]).count == (state == "blocked" ? 2 : 0))
    }

    @Test func taskIDsStayLocalToEachProgram() throws {
        var attention = RexAttention()
        let reports = [
            RexAttentionRecord(sessionID: "s", blockID: "first", recordID: "build", state: "blocked", updatedAt: time,
                app: "builder", title: "Build", terminalTitle: "Build"),
            RexAttentionRecord(sessionID: "s", blockID: "second", recordID: "build", state: "blocked", updatedAt: time,
                app: "other-builder", title: "Build", terminalTitle: "Notes"),
            RexAttentionRecord(sessionID: "s", blockID: "third", recordID: "build", state: "blocked", updatedAt: time,
                app: "builder", title: "Release", terminalTitle: "Notes"),
        ]
        attention.update(reports)
        #expect(try attention.unseenRecords(preferences: ["Workspace.programActivitySeen": [:]]) == reports)
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
