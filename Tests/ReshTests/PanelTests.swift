import AppKit
import Foundation
import ReshCore
import Testing
@testable import Resh

/// Opt-in AppKit integration tests.
@Suite("Native panel", .serialized)
struct PanelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESH_UI_TESTS"] == "1"))
    @MainActor func reopeningShowsThePreparedListAndSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resh-panel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml"), rex = root.appendingPathComponent("rex")
        try "".write(to: config, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        case " $* " in
          *" hosts "*) printf '{"hosts":[]}\\n' ;;
          *) exec /bin/sleep 30 ;;
        esac
        """.write(to: rex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rex.path)
        let tools = Tools(rex: rex.path, zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let sessions = ["First", "Second", "Third"].map { RexSession(sessionID: $0, label: $0) }
        _ = NSApplication.shared
        let controller = PanelController(service: ReshService(client: RexClient(tools: tools, target: RexTarget())),
            tools: tools, sessions: sessions, configurationURL: config, readTheme: { _, _ in .fixture })
        defer {
            controller.dismiss(focusRex: false)
            controller.model.clear()
        }
        controller.show()
        await controller.model.loadingTask?.value
        await controller.model.hostsTask?.value
        let size = controller.panel.frame.size
        controller.model.query = "second"
        #expect(controller.model.results.count == 1)
        controller.dismiss(focusRex: false)
        controller.show()
        let frame = controller.panel.frame
        #expect(controller.model.query.isEmpty && controller.model.results.count == sessions.count)
        #expect(frame.size == size && !controller.model.isLoading)
        await Task.yield()
        #expect(controller.panel.frame == frame)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESH_UI_TESTS"] == "1"))
    @MainActor func sessionAttentionDotLayoutAndReuse() {
        _ = NSApplication.shared
        let cell = SessionCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 27))
        let session = Candidate(id: "s", kind: .session, title: "Ready session", sessionID: "s")
        cell.configure(session, needsAttention: true, color: .systemBlue, textColor: .labelColor)
        cell.layoutSubtreeIfNeeded()
        #expect(!cell.attention.isHidden)
        #expect(cell.textField!.frame.width >= ceil(cell.textField!.cell!.cellSize.width))
        #expect(cell.attention.frame.minX == cell.textField!.frame.maxX + 6)
        #expect(cell.attention.frame.maxX < cell.bounds.maxX)
        #expect(cell.accessibilityLabel()?.contains("unread activity") == true)
        let long = Candidate(id: "long", kind: .session, title: String(repeating: "long-session-", count: 20), sessionID: "s")
        cell.configure(long, needsAttention: true, color: .systemBlue, textColor: .white)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.attention.frame.maxX <= cell.bounds.maxX - 8)
        cell.configure(session, needsAttention: false, color: .systemBlue, textColor: .labelColor)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.attention.isHidden && cell.toolTip == nil)
        #expect(cell.textField!.frame.width == cell.bounds.width - 16)
        #expect(cell.accessibilityLabel()?.contains("unread activity") == false)
        cell.configure(Candidate(id: "folder", kind: .directory, title: "folder", path: "/folder"),
            needsAttention: true, color: .systemBlue, textColor: .labelColor)
        #expect(cell.attention.isHidden)
        let host = RexHost(id: "host:build", label: "Build server", endpoints: ["https://build.example"])
        let remote = Candidate(id: "remote", kind: .session, title: long.title, sessionID: "remote", host: host)
        cell.configure(remote, needsAttention: true, color: .systemBlue, textColor: .white, showHost: true)
        cell.layoutSubtreeIfNeeded()
        #expect(!cell.hostLabel.isHidden && cell.hostLabel.stringValue == host.label)
        #expect(cell.attention.frame.maxX < cell.hostLabel.frame.minX)
        #expect(cell.hostLabel.frame.maxX == cell.bounds.maxX - 8)
        #expect(cell.accessibilityLabel()?.contains(host.label) == true)
        cell.configure(session, needsAttention: false, color: .systemBlue, textColor: .labelColor)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.hostLabel.isHidden && cell.textField!.frame.width == cell.bounds.width - 16)
    }

    /// Read-only end-to-end check against a session that Rex currently marks unread.
    /// Opt in with RESH_LIVE_ATTENTION_SESSION; never creates/selects a Rex session.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESH_UI_TESTS"] == "1"
        && ProcessInfo.processInfo.environment["RESH_LIVE_ATTENTION_SESSION"] != nil))
    @MainActor func liveUnreadSessionAndFullWidthTitles() async throws {
        let name = try #require(ProcessInfo.processInfo.environment["RESH_LIVE_ATTENTION_SESSION"])
        let tools = try Tools.discover(), client = RexClient(tools: tools, target: RexTarget())
        let sessions = try await Task.detached { try client.sessions() }.value
        let expected = try #require(sessions.first { $0.label == name })
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("resh-live-" + UUID().uuidString + ".toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        _ = NSApplication.shared
        let controller = PanelController(service: ReshService(client: client), tools: tools, sessions: sessions, configurationURL: config)
        defer { controller.dismiss(focusRex: false) }
        controller.show()
        await controller.model.loadingTask?.value
        for _ in 0..<300 {
            if controller.model.attentionSessionIDs.contains(expected.sessionID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.model.attentionSessionIDs.contains(expected.sessionID))
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        controller.panel.displayIfNeeded()
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        let content = try #require(controller.panel.contentView)
        let table = try #require(findTable(content))
        for (row, entry) in controller.model.results.enumerated() {
            let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionCellView)
            cell.layoutSubtreeIfNeeded()
            let field = try #require(cell.textField)
            #expect(field.stringValue == entry.displayTitle)
            // All live session names fit this picker. Check the rendered field,
            // not just its string value or its accessibility label.
            #expect(field.frame.width >= ceil(field.cell!.cellSize.width))
            #expect(cell.attention.isHidden == !controller.model.attentionSessionIDs.contains(entry.sessionID!))
        }
        if let path = ProcessInfo.processInfo.environment["RESH_UI_SNAPSHOT"],
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESH_UI_TESTS"] == "1"))
    @MainActor func renderedSessionNamesAndUnreadDotRegression() async throws {
        let titles = [
            "first-session", "second-session", "third-session", "app",
            "example-background-task", "example-integration-task",
        ]
        let sessions = titles.enumerated().map { RexSession(sessionID: "synthetic-\($0.offset)", label: $0.element) }
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("resh-render-" + UUID().uuidString + ".toml")
        let rex = config.appendingPathExtension("rex")
        try "".write(to: config, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf '{\"hosts\":[]}\\n'\n".write(to: rex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rex.path)
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: rex)
        }
        let tools = Tools(rex: rex.path, zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        _ = NSApplication.shared
        let model = SearchModel(service: ReshService(client: RexClient(tools: tools, target: RexTarget())),
            tools: tools, sessions: sessions, configurationURL: config, readTheme: { _, _ in .fixture },
            readPreferences: { ["Workspace.programActivitySeen": [:]] })
        defer { model.clear() }
        let picker = PanelView(model: model)
        model.loadInitial()
        await model.loadingTask?.value
        await model.hostsTask?.value
        // Deterministic rendering fixture; never injects status into a real Rex terminal.
        model.updateAttention([RexAttentionRecord(sessionID: "synthetic-2", blockID: "synthetic-block",
            state: "done", updatedAt: "2026-10-22T18:21:56.923423Z")])
        await model.attentionTask?.value
        picker.layoutSubtreeIfNeeded()
        let buttons = picker.subviews.compactMap { ($0 as? NSScrollView)?.documentView }
            .flatMap(\.subviews).compactMap { $0 as? NSButton }
        #expect(buttons.map { $0.accessibilityIdentifier() } == ["resh.scope.sessions"])
        let table = try #require(picker.subviews.compactMap { $0 as? NSScrollView }
            .compactMap { $0.documentView as? NSTableView }.first)
        #expect(table.numberOfRows == titles.count)
        for (row, title) in titles.enumerated() {
            let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionCellView)
            cell.layoutSubtreeIfNeeded()
            let field = try #require(cell.textField)
            #expect(field.stringValue == title)
            #expect(field.frame.width >= ceil(field.cell!.cellSize.width))
            #expect(cell.attention.isHidden == (row != 2))
        }
        if let path = ProcessInfo.processInfo.environment["RESH_UI_REGRESSION_SNAPSHOT"],
           let bitmap = picker.bitmapImageRepForCachingDisplay(in: picker.bounds) {
            picker.cacheDisplay(in: picker.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        model.selection = 2
        model.receive(.success(.sessions([RexSession(sessionID: "new", label: "new-session")] + sessions)))
        #expect(table.numberOfRows == titles.count + 1)
        #expect(model.selected?.id == "synthetic-2")
        #expect(table.selectedRow == model.selection && model.selection == 3)
    }
}
