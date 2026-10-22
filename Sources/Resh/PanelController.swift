import AppKit
import Combine
import Darwin
import ReshCore

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Keep native controls warm; replace session data on every invocation and clear it on hide.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: LauncherPanel
    let model: SearchModel
    private var monitor: Any?
    private var themeTimer: Timer?
    private let attentionConnection: RexAttentionConnection
    private var attentionGeneration = 0
    private var subscriptions = Set<AnyCancellable>()
    private var picker: PanelView?
    private var rexPID: Int32?
    private var isDismissing = false
    private var smokeTest: String?
    private var panelReadyMilliseconds = 0.0
    private var frontmostPID: Int32?
    private var requestStarted: Double?
    private var requestToPanelMilliseconds = 0.0
    private var presentationCount = 0
    private var presentationStages: [String: Double] = [:]
    var terminateOnDismiss = false
    var nativeHotkeyStartedAt: Double?
    private var nativeHotkeyToPanelMilliseconds: Double?
    private let defaultConfigurationURL: URL

    init(service: ReshService, tools: Tools, sessions: [RexSession]? = nil, smokeTest: String? = nil, configurationURL: URL = ConfigurationFile.url()) {
        self.model = SearchModel(service: service, tools: tools, sessions: sessions, configurationURL: configurationURL)
        self.attentionConnection = RexAttentionConnection(tools: tools)
        self.defaultConfigurationURL = configurationURL
        LaunchMetrics.mark("model")
        self.smokeTest = smokeTest
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width,
            height: PanelLayout.height(resultCount: sessions?.count ?? 0)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        LaunchMetrics.mark("windowCreated")
        super.init()
        panel.delegate = self
        panel.title = "resh"
        panel.identifier = NSUserInterfaceItemIdentifier("resh.search.panel")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .default
        panel.isFloatingPanel = true
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
        if let picker { panel.makeFirstResponder(picker.searchField) }
        LaunchMetrics.mark("viewCreated")
    }

    func prepare(service: ReshService, request: LauncherRequest) {
        smokeTest = request.smokeTest
        requestStarted = request.sentAt
        presentationStages = [:]
        markPresentation("received")
        model.prepare(service: service, sessions: request.sessions,
            configurationURL: request.config.map { URL(fileURLWithPath: $0) } ?? defaultConfigurationURL)
        markPresentation("prepared")
    }

    func present(error: Error) {
        show()
        let presentation = presentationCount
        Task {
            await model.loadingTask?.value
            if presentationCount == presentation, panel.isVisible { model.error = error.localizedDescription }
        }
    }

    private func markPresentation(_ name: String) {
        presentationStages[name] = (ProcessInfo.processInfo.systemUptime - (requestStarted ?? LaunchMetrics.processStarted)) * 1000
    }

    func show() {
        isDismissing = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        themeTimer?.invalidate()
        presentationCount += 1
        let frontmost = NSWorkspace.shared.frontmostApplication
        frontmostPID = frontmost?.processIdentifier
        markPresentation("frontmost")
        if frontmost?.bundleIdentifier == "com.superlogical.rex" { rexPID = frontmost?.processIdentifier }
        position()
        LaunchMetrics.mark("positioned")
        markPresentation("positioned")
        panel.makeKeyAndOrderFront(nil)
        LaunchMetrics.mark("orderedFront")
        markPresentation("orderedFront")
        if let picker { panel.makeFirstResponder(picker.searchField) }
        LaunchMetrics.mark("focused")
        markPresentation("focused")
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panelReadyMilliseconds = (ProcessInfo.processInfo.systemUptime - LaunchMetrics.processStarted) * 1000
        requestToPanelMilliseconds = (ProcessInfo.processInfo.systemUptime - (requestStarted ?? LaunchMetrics.processStarted)) * 1000
        nativeHotkeyToPanelMilliseconds = nativeHotkeyStartedAt.map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 }
        LaunchMetrics.mark("displayed")
        markPresentation("displayed")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
        themeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.refreshTheme()
                self?.model.refreshAttention()
            }
        }
        attentionGeneration += 1
        let attentionRequest = attentionGeneration
        attentionConnection.start(target: model.service.target) { [weak self] records in
            Task { @MainActor [weak self] in
                guard let self, attentionGeneration == attentionRequest, panel.isVisible else { return }
                model.updateAttention(records)
            }
        }
        model.loadInitial()
        model.refreshTheme()
        if rexPID == nil {
            Task {
                if let client = try? await model.service.resolveClient() {
                    rexPID = client.pid
                }
            }
        }
        if let smokeTest {
            Task { await runSmokeTest(output: smokeTest) }
        }
    }

    private func apply(theme: RexTheme) {
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let view: PanelView
        if let picker {
            view = picker
            view.apply(theme: theme)
        } else {
            view = PanelView(model: model)
            picker = view
        }
        view.frame = NSRect(origin: .zero, size: panel.frame.size)
        let material: NSView
        let glass = theme.usesGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if glass, #available(macOS 26.0, *) {
            let effect = NSGlassEffectView(frame: view.frame)
            effect.style = .regular
            effect.cornerRadius = 16
            effect.tintColor = theme.usesTint ? theme.panelBackground.nsColor.withAlphaComponent(0.35) : nil
            effect.contentView = view
            material = effect
        } else if glass {
            let effect = NSVisualEffectView(frame: view.frame)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(view)
            material = effect
        } else {
            let solid = NSView(frame: view.frame)
            solid.wantsLayer = true
            solid.layer?.backgroundColor = theme.panelBackground.nsColor.cgColor
            solid.addSubview(view)
            material = solid
        }
        material.wantsLayer = true
        material.layer?.cornerRadius = 16
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        material.layer?.borderColor = theme.foreground.nsColor.withAlphaComponent(0.18).cgColor
        panel.contentView = material
        if panel.isKeyWindow { panel.makeFirstResponder(view.searchField) }
    }

    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let shortcut = model.configuration.keymap.action(for: KeyChord(code: event.keyCode,
            command: modifiers.contains(.command), control: modifiers.contains(.control),
            option: modifiers.contains(.option), shift: modifiers.contains(.shift))) else { return false }
        switch shortcut {
        case let .scope(scope): model.changeScope(scope)
        case let .move(delta): model.move(delta)
        case .open: model.openSelection()
        case .dismiss: if !model.isConnecting { dismiss(focusRex: true) }
        case .delete: model.deleteSelection()
        case .ignore: break
        case .reload: model.reload()
        case .nextSource: model.cycleSource(1)
        case .previousSource: model.cycleSource(-1)
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

    private func position() {
        // Enumerating other apps' windows can stall WindowServer for ~500 ms.
        // Position directly on the pointer's display instead; no geometry cache or permissions.
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let pointer = NSEvent.mouseLocation
        let screen = screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? primary
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = max(visible.minX + 10, min(visible.midX - size.width / 2, visible.maxX - size.width - 10))
        let y = max(visible.minY + 10, min(visible.midY - size.height / 2 + 65, visible.maxY - size.height - 10))
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
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        themeTimer?.invalidate()
        stopAttention()
        panel.orderOut(nil)
        if focusRex, NSApp.isActive, let rexPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != rexPID {
            NSRunningApplication(processIdentifier: rexPID)?.activate(options: [])
        }
        model.clear()
        if terminateOnDismiss { NSApp.terminate(nil) }
    }

    func stopAttention() {
        attentionGeneration += 1
        attentionConnection.stop()
    }

    private func runSmokeTest(output: String) async {
        await model.loadingTask?.value
        markPresentation("resultsReady")
        // First paint deliberately doesn't await activity. A smoke screenshot
        // must, or it can falsely "verify" an empty list of notification dots.
        for _ in 0..<200 {
            if model.receivedAttentionSnapshot { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await model.attentionTask?.value
        markPresentation("attentionReady")
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        var report: [String: Any] = ["visible": panel.isVisible, "keyWindow": panel.isKeyWindow,
            "searchFocused": panel.firstResponder is NSTextView,
            "sessionCount": model.sessionCount, "initialSessionTitles": model.results.map(\.title),
            "liveSessionSnapshot": model.receivedLiveSnapshot,
            "attentionSnapshotReceived": model.receivedAttentionSnapshot,
            "attentionSessionIDs": model.attentionSessionIDs.sorted(),
            "renderedRows": picker?.visibleRowDiagnostics() ?? [],
            "panelReadyMs": panelReadyMilliseconds,
            "requestToPanelMs": requestToPanelMilliseconds, "pid": getpid(), "presentationCount": presentationCount,
            "nativeHotkeyToPanelMs": nativeHotkeyToPanelMilliseconds as Any? ?? NSNull(),
            "presentationStagesMs": presentationStages,
            "applicationReadyMs": LaunchMetrics.applicationReadyMilliseconds,
            "startupStagesMs": LaunchMetrics.stages,
            "themeReadMs": model.themeReadMilliseconds,
            "nonactivating": panel.styleMask.contains(.nonactivatingPanel),
            "frontmostApplicationPreserved": frontmostPID == NSWorkspace.shared.frontmostApplication?.processIdentifier,
            "error": model.error as Any? ?? NSNull()]
        if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + ".png"))
        }
        if !terminateOnDismiss {
            dismiss(focusRex: false)
            report["hidden"] = !panel.isVisible
            report["sessionDataClearedOnHide"] = model.sessionCount == 0 && model.folderCount == 0
                && model.query.isEmpty && model.results.isEmpty && model.attentionSessionIDs.isEmpty
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output + ".json"), options: .atomic)
            FileHandle.standardOutput.write(data)
        }
        dismiss(focusRex: false)
    }
}
