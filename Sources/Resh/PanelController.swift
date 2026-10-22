import AppKit
import Combine
import CoreGraphics
import Darwin
import ReshCore

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// There is no resident daemon or session cache: the panel exits when dismissed.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: LauncherPanel
    let model: SearchModel
    private var monitor: Any?
    private var themeTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var background: NSView?
    private var picker: PanelView?
    private var rexPID: Int32?
    private var isDismissing = false
    private let smokeTest: String?
    private var panelReadyMilliseconds = 0.0

    init(service: ReshService, tools: Tools, sessions: [RexSession]? = nil, smokeTest: String? = nil) {
        self.model = SearchModel(service: service, tools: tools, sessions: sessions)
        self.smokeTest = smokeTest
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width,
            height: PanelLayout.height(resultCount: sessions?.count ?? 0)),
            styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.title = "resh"
        panel.identifier = NSUserInterfaceItemIdentifier("resh.search.panel")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        model.onDismiss = { [weak self] focusRex in self?.dismiss(focusRex: focusRex) }
        model.$theme.dropFirst().sink { [weak self] theme in self?.apply(theme: theme) }.store(in: &subscriptions)
        model.$results.dropFirst().sink { [weak self] entries in
            self?.resize(resultCount: entries.count, hasError: self?.model.error != nil)
        }.store(in: &subscriptions)
        model.$error.dropFirst().sink { [weak self] error in
            self?.resize(resultCount: self?.model.results.count ?? 0, hasError: error != nil)
        }.store(in: &subscriptions)
        apply(theme: model.theme)
    }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == "com.superlogical.rex" { rexPID = frontmost?.processIdentifier }
        position(over: frontmost?.processIdentifier)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let picker { panel.makeFirstResponder(picker.searchField) }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panelReadyMilliseconds = (ProcessInfo.processInfo.systemUptime - LaunchMetrics.processStarted) * 1000
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
        themeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshTheme() }
        }
        model.loadInitial()
        if rexPID == nil {
            Task {
                if let client = try? await model.service.resolveClient() {
                    rexPID = client.pid
                    if let pid = client.pid { position(over: pid) }
                }
            }
        }
        if let smokeTest {
            Task { await runSmokeTest(output: smokeTest) }
        }
    }

    private func apply(theme: RexTheme) {
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let view = picker ?? PanelView(model: model)
        picker = view
        view.apply(theme: theme)
        view.frame = NSRect(origin: .zero, size: panel.frame.size)
        view.autoresizingMask = [.width, .height]
        let material: NSView
        let glass = theme.usesGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if glass, #available(macOS 26.0, *) {
            let effect = NSGlassEffectView(frame: view.frame)
            effect.style = .clear
            effect.cornerRadius = 10
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
        material.layer?.cornerRadius = 10
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        material.layer?.borderColor = theme.foreground.nsColor.withAlphaComponent(0.12).cgColor
        background = material
        panel.contentView = material
        if panel.isKeyWindow { panel.makeFirstResponder(view.searchField) }
    }

    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let shortcut = PanelShortcut.action(keyCode: event.keyCode,
            command: modifiers.contains(.command), control: modifiers.contains(.control),
            option: modifiers.contains(.option), shift: modifiers.contains(.shift)) else { return false }
        switch shortcut {
        case let .scope(scope): model.changeScope(scope)
        case let .move(delta): model.move(delta)
        case .open: model.openSelection()
        case .dismiss: if !model.isConnecting { dismiss(focusRex: true) }
        case .delete: model.deleteSelection()
        case .ignore: break
        }
        return true
    }

    private func resize(resultCount: Int, hasError: Bool) {
        var frame = panel.frame
        let height = PanelLayout.height(resultCount: resultCount, hasError: hasError)
        frame.origin.y = frame.maxY - height // Keep the search field stationary.
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
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
        try? await Task.sleep(for: .milliseconds(30))
        let initialCount = model.results.count
        let initialHeight = panel.frame.height
        let focused = panel.firstResponder is NSTextView
        // Returning to the already-present sessions must not await filesystem work.
        model.changeScope(.find)
        model.changeScope(.sessions)
        let sessionsDoNotWaitForFolders = !model.isLoading && model.results.count == initialCount
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "@", charactersIgnoringModifiers: "@", isARepeat: false, keyCode: 19) {
            _ = handle(event)
        }
        let sourceShortcutWorks = model.scope == .all
        await model.loadingTask?.value
        let allCount = model.results.count
        if let editor = panel.firstResponder as? NSTextView {
            editor.insertText("resh", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }
        await Task.yield()
        let nativeTypingWorks = model.query == "resh"
        let filtered = model.results.map(\.title)
        model.query = ""
        model.selection = 0
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125) {
            _ = handle(event)
        }
        let arrowWorks = model.results.count < 2 || model.selection == 1
        let sessionPathsHidden = model.catalog.sessions.allSatisfy { $0.path == nil && $0.subtitle.isEmpty }
        let russianSave = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "ы", charactersIgnoringModifiers: "ы", isARepeat: false, keyCode: 1)!
        let saveWorksInRussian = handle(russianSave)
        let nativeSelectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "ф", charactersIgnoringModifiers: "ф", isARepeat: false, keyCode: 0)!
        let nativeEditingUnclaimed = !handle(nativeSelectAll)
        model.changeScope(.sessions)
        model.selection = 0
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let report: [String: Any] = ["visible": panel.isVisible, "keyWindow": panel.isKeyWindow,
            "searchFocused": focused, "sessionCount": initialCount, "allCount": allCount,
            "fuzzyResults": filtered, "arrowNavigation": arrowWorks,
            "sourceShortcut": sourceShortcutWorks,
            "russianSaveKey": saveWorksInRussian, "nativeEditingUnclaimed": nativeEditingUnclaimed,
            "sessionPathsHidden": sessionPathsHidden, "liveSessionSnapshot": model.receivedLiveSnapshot,
            "sessionsDoNotWaitForFolders": sessionsDoNotWaitForFolders,
            "panelReadyMs": panelReadyMilliseconds, "initialHeight": initialHeight,
            "nativeTypingUpdatesQuery": nativeTypingWorks,
            "applicationReadyMs": LaunchMetrics.applicationReadyMilliseconds,
            "themeReadMs": model.themeReadMilliseconds,
            "width": panel.frame.width, "rowHeight": PanelLayout.rowHeight,
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
