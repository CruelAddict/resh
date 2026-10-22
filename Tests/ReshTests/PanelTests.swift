import AppKit
import Foundation
import ReshCore
import Testing
@testable import Resh

/// Opt-in AppKit integration; record-demo.py can record this same scenario.
@Suite("Native panel", .serialized)
struct PanelTests {
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
        try press("escape")
        if recording != nil {
            let report: [String: Any] = ["input": "synthetic AppKit events", "sessionData": "synthetic", "stages": stages]
            try JSONSerialization.data(withJSONObject: report).write(to: root.appendingPathComponent("report.json"))
            try await waitFor("recording-stopped")
        }
    }
}
