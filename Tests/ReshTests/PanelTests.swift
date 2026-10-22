import AppKit
import Foundation
import ReshCore
import Testing
@testable import Resh

/// Opt-in AppKit integration; record-demo.py can record this same scenario.
@Suite("Native panel", .serialized)
struct PanelTests {
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
        let titles = ["gentle-spire", "dawn-spire", "drifting-mesa", "resh", "service-payment-session", "service-installments-api"]
        let sessions = titles.enumerated().map { RexSession(sessionID: "synthetic-\($0.offset)", label: $0.element) }
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("resh-render-" + UUID().uuidString + ".toml")
        try "".write(to: config, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: config) }
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: (try? Tools.discover())?.rexApp ?? "/not/Rex.app")
        _ = NSApplication.shared
        let controller = PanelController(service: ReshService(client: RexClient(tools: tools, target: RexTarget())),
            tools: tools, sessions: sessions, configurationURL: config)
        defer { controller.dismiss(focusRex: false) }
        controller.show()
        await controller.model.loadingTask?.value
        controller.stopAttention()
        // Deterministic rendering fixture; never injects status into a real Rex terminal.
        controller.model.updateAttention([RexAttentionRecord(sessionID: "synthetic-2", blockID: "synthetic-block",
            state: "done", updatedAt: "2026-10-22T18:21:56.923423Z")])
        await controller.model.attentionTask?.value
        let content = try #require(controller.panel.contentView)
        content.layoutSubtreeIfNeeded()
        controller.panel.displayIfNeeded()
        func findPicker(_ view: NSView) -> PanelView? {
            if let picker = view as? PanelView { return picker }
            return view.subviews.lazy.compactMap { findPicker($0) }.first
        }
        let picker = try #require(findPicker(content))
        let rows = picker.visibleRowDiagnostics()
        #expect(rows.compactMap { $0["title"] as? String } == titles)
        for row in rows {
            #expect((row["fieldWidth"] as! CGFloat) >= (row["fittingWidth"] as! CGFloat))
            #expect((row["hasDot"] as? Bool) == ((row["title"] as? String) == "drifting-mesa"))
        }
        if let path = ProcessInfo.processInfo.environment["RESH_UI_REGRESSION_SNAPSHOT"],
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESH_UI_TESTS"] == "1"
        || ProcessInfo.processInfo.environment["RESH_UI_DEMO_ROOT"] != nil))
    @MainActor func nativePanelInputAndReuse() async throws {
        let recording = ProcessInfo.processInfo.environment["RESH_UI_DEMO_ROOT"].map { URL(fileURLWithPath: $0) }
        let root = recording ?? FileManager.default.temporaryDirectory.appendingPathComponent("resh-panel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if recording == nil { try? FileManager.default.removeItem(at: root) } }
        for name in ["alpha", "beta"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let config = root.appendingPathComponent("config.toml")
        try """
        source_order = ["sessions", "all", "work"]
        [keymap]
        "ctrl+w" = "source:work"
        [[sources]]
        id = "work"
        title = "Work"
        type = "paths"
        paths = ["alpha", "beta"]
        """.write(to: config, atomically: true, encoding: .utf8)
        let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")
        let service = ReshService(client: RexClient(tools: tools, target: RexTarget()))
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = PanelController(service: service, tools: tools, configurationURL: config)
        let backdrop = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let caption = NSTextField(wrappingLabelWithString: "")
        if recording != nil {
            backdrop.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            backdrop.level = .floating
            backdrop.center()
            caption.font = .systemFont(ofSize: 22, weight: .medium)
            caption.textColor = .white
            caption.frame = NSRect(x: 36, y: 40, width: 890, height: 100)
            backdrop.contentView?.addSubview(caption)
            backdrop.orderFrontRegardless()
        }
        defer { controller.dismiss(focusRex: false); backdrop.orderOut(nil) }
        func show(_ title: String) async {
            controller.model.prepare(service: service, sessions: [RexSession(sessionID: title, label: title)])
            controller.show()
            await controller.model.loadingTask?.value
            if recording != nil {
                controller.panel.setFrameOrigin(NSPoint(x: backdrop.frame.midX - controller.panel.frame.width / 2,
                    y: backdrop.frame.midY - 30))
            }
        }
        func press(_ key: String, characters: String = "") throws {
            let chord = try KeyChord(key)
            let flags: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
            let modifiers = flags.enumerated().reduce(NSEvent.ModifierFlags()) {
                chord.modifiers & (1 << $1.offset) != 0 ? $0.union($1.element) : $0
            }
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: controller.panel.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: chord.code))
            #expect(controller.handle(event))
        }
        func waitFor(_ name: String) async throws {
            for _ in 0..<1500 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw ReshError("Recorder did not create \(name)")
        }
        var stages: [String] = []
        func stage(_ text: String) async throws {
            stages.append(text)
            guard recording != nil else { return }
            caption.stringValue = text
            for _ in 0..<60 {
                backdrop.displayIfNeeded(); controller.panel.displayIfNeeded(); app.updateWindows()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        await show("Session one")
        if recording != nil {
            let frame = backdrop.frame, top = NSScreen.screens.first?.frame.maxY ?? 0
            let ready: [String: Any] = ["rect": [Int(frame.minX), Int(top - frame.maxY), Int(frame.width), Int(frame.height)],
                "scale": NSScreen.screens.first?.backingScaleFactor ?? 1]
            try JSONSerialization.data(withJSONObject: ready).write(to: root.appendingPathComponent("ready.json"))
            try await waitFor("recording-ready")
        }
        try press("ctrl+w", characters: "ц")
        await controller.model.loadingTask?.value
        #expect(controller.model.results.map(\.title) == ["alpha", "beta"])
        try await stage("Ctrl+W → custom folders, using a physical key with Russian characters")
        let editor = try #require(controller.panel.firstResponder as? NSTextView)
        editor.insertText("beta", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(controller.model.query == "beta" && controller.model.results.map(\.title) == ["beta"])
        try await stage("Native text input filters the list")
        editor.selectAll(nil)
        #expect(editor.selectedRange().length == 4)
        editor.insertText("", replacementRange: editor.selectedRange())
        try press("ctrl+n")
        #expect(controller.model.selected?.title == "beta")
        try press("ctrl+p")
        #expect(controller.model.selected?.title == "alpha")
        try await stage("Select-all, clear and keyboard navigation use the native editor")
        try press("escape")
        #expect(!controller.panel.isVisible && controller.model.results.isEmpty)
        await show("Fresh session")
        try press("cmd+2", characters: "@")
        await controller.model.loadingTask?.value
        #expect(controller.model.scope == .all && controller.model.results.map(\.title) == ["Fresh session"])
        try await stage("The same panel reopens with a fresh snapshot; Cmd+2 switches sources")
        try press("ctrl+[", characters: "\u{1b}")
        #expect(!controller.panel.isVisible && controller.model.results.isEmpty)
        if recording != nil {
            let report: [String: Any] = ["input": "synthetic AppKit events", "sessionData": "synthetic", "stages": stages]
            try JSONSerialization.data(withJSONObject: report).write(to: root.appendingPathComponent("report.json"))
            try await waitFor("recording-stopped")
        }
    }
}
