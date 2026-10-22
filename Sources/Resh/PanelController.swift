import AppKit
import Combine
import CoreGraphics
import Darwin
import ReshCore
import SwiftUI

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// There is no resident daemon: the panel exits when dismissed.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: LauncherPanel
    let model: SearchModel
    private var monitor: Any?
    private var themeTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var background: NSView?
    private var hosting: NSHostingView<PanelView>?
    private var rexPID: Int32?
    private var isDismissing = false
    private let smokeTest: String?

    init(service: ReshService, tools: Tools, smokeTest: String? = nil) {
        self.model = SearchModel(service: service, tools: tools)
        self.smokeTest = smokeTest
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 520),
            styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "resh"
        panel.identifier = NSUserInterfaceItemIdentifier("resh.search.panel")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        model.onDismiss = { [weak self] focusRex in self?.dismiss(focusRex: focusRex) }
        model.$theme.dropFirst().sink { [weak self] theme in self?.apply(theme: theme) }.store(in: &subscriptions)
        apply(theme: model.theme)
    }

    func show() {
        position(over: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
        themeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshTheme() }
        }
        model.reload()
        Task {
            if let client = try? await model.service.resolveClient() {
                rexPID = client.pid
                if let pid = client.pid { position(over: pid) }
            }
        }
        if let smokeTest {
            Task { await runSmokeTest(output: smokeTest) }
        }
    }

    private func apply(theme: RexTheme) {
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let view = NSHostingView(rootView: PanelView(model: model))
        view.sizingOptions = []
        view.frame = NSRect(x: 0, y: 0, width: 740, height: 520)
        view.autoresizingMask = [.width, .height]
        let material: NSView
        let glass = theme.usesGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if glass, #available(macOS 26.0, *) {
            let effect = NSGlassEffectView(frame: view.frame)
            effect.style = .clear
            effect.cornerRadius = 20
            effect.tintColor = theme.usesTint ? theme.background.nsColor.withAlphaComponent(0.45) : nil
            effect.contentView = view
            material = effect
        } else if glass {
            let effect = NSVisualEffectView(frame: view.frame)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(view)
            if theme.usesTint {
                effect.wantsLayer = true
                effect.layer?.backgroundColor = theme.background.nsColor.withAlphaComponent(0.35).cgColor
            }
            material = effect
        } else {
            let solid = NSView(frame: view.frame)
            solid.wantsLayer = true
            solid.layer?.backgroundColor = theme.background.nsColor.cgColor
            solid.addSubview(view)
            material = solid
        }
        material.wantsLayer = true
        material.layer?.cornerRadius = 20
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        material.layer?.borderColor = theme.foreground.nsColor.withAlphaComponent(0.12).cgColor
        hosting = view; background = material
        panel.contentView = material
    }

    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "s" { return true }
            return false // Preserve native copy/paste/select-all.
        }
        if modifiers.contains(.control), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "a": model.changeScope(.all)
            case "t": model.changeScope(.sessions)
            case "x": model.changeScope(.directories)
            case "f": model.changeScope(.find)
            case "d": model.deleteSelection()
            case "n": model.move(1)
            case "p": model.move(-1)
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 53: if !model.isConnecting { dismiss(focusRex: true) }; return true
        case 125: model.move(1); return true
        case 126: model.move(-1); return true
        case 48: model.move(modifiers.contains(.shift) ? -1 : 1); return true
        case 36, 76: model.openSelection(); return true
        default: return false
        }
    }

    private func position(over pid: Int32?) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        var reference = NSScreen.main?.visibleFrame ?? primary.visibleFrame
        if let pid, let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
           let window = windows.first(where: {
               ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
           }), let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
           let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] {
            reference = NSRect(x: x, y: primary.frame.maxY - y - h, width: w, height: h)
        }
        let screen = screens.first { $0.frame.intersects(reference) } ?? primary
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = max(visible.minX + 10, min(reference.midX - size.width / 2, visible.maxX - size.width - 10))
        let y = max(visible.minY + 10, min(reference.midY - size.height / 2 + 65, visible.maxY - size.height - 10))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !model.isConnecting, !model.isPresentingConfirmation, smokeTest == nil, NSApp.modalWindow == nil else { return }
        dismiss(focusRex: false)
    }

    func dismiss(focusRex: Bool) {
        guard !isDismissing else { return }
        if smokeTest != nil { FileHandle.standardError.write(Data("resh smoke: Dismissing panel\n".utf8)) }
        isDismissing = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        themeTimer?.invalidate()
        panel.orderOut(nil)
        if focusRex, let rexPID { NSRunningApplication(processIdentifier: rexPID)?.activate(options: []) }
        NSApp.terminate(nil)
    }

    private func runSmokeTest(output: String) async {
        FileHandle.standardError.write(Data("resh smoke: Waiting for catalog\n".utf8))
        await model.loadingTask?.value
        try? await Task.sleep(for: .milliseconds(350))
        let initialCount = model.results.count
        let focused = panel.firstResponder is NSTextView
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) {
            _ = handle(event)
        }
        let sourceShortcutWorks = model.scope == .all
        let allCount = model.results.count
        model.query = "resh"
        let filtered = model.results.map(\.title)
        model.query = ""
        model.selection = 0
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125) {
            _ = handle(event)
        }
        let arrowWorks = model.results.count < 2 || model.selection == 1
        model.selection = 0
        let report: [String: Any] = ["visible": panel.isVisible, "keyWindow": panel.isKeyWindow,
            "searchFocused": focused, "sessionCount": initialCount, "allCount": allCount,
            "fuzzyResults": filtered, "arrowNavigation": arrowWorks,
            "sourceShortcut": sourceShortcutWorks,
            "theme": model.theme.name, "glass": model.theme.usesGlass,
            "error": model.error as Any? ?? NSNull()]
        panel.contentView?.layoutSubtreeIfNeeded()
        if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + ".png"))
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output + ".json"))
            FileHandle.standardOutput.write(data)
        }
        dismiss(focusRex: false)
    }
}
