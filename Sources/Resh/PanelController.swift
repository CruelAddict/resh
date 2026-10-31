import AppKit
import Combine
import ReshCore

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A reusable view of application-owned state. Opening never clears the catalog.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: LauncherPanel
    let model: SearchModel
    var onDismiss: (() -> Void)?
    private var monitor: Any?
    private var outsideClickMonitor: Any?
    private var themeTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var picker: PanelView?
    private var rexAppPID: Int32?
    private var presentationAppPID: Int32?
    private(set) var positioningTask: Task<Void, Never>?
    private var lastScreenID: CGDirectDisplayID?
    private let readWindowFrame: @Sendable (Int32?) -> CGRect?
    private let readScreens: () -> [NSScreen]
    private var isDismissing = false
    private var keyRuntime = KeymapRuntime()
    private static let permissionPromptBundleID = "com.apple.UserNotificationCenter"

    init(service: ReshService, tools: Tools, sessions: [RexSession] = [], configurationURL: URL? = nil,
         snapshotProvider: (any RexSnapshotProviding)? = nil,
         readWindowFrame: @escaping @Sendable (Int32?) -> CGRect? = { $0.flatMap { PanelPlacement.windowFrame(rexAppPID: $0) } },
         readScreens: @escaping () -> [NSScreen] = { NSScreen.screens },
         readTheme: @escaping @Sendable (String, Bool) throws -> RexTheme = { try RexTheme.read(rexApp: $0, systemIsDark: $1) }) {
        self.model = SearchModel(service: service, tools: tools, sessions: sessions, configurationURL: configurationURL,
            snapshotProvider: snapshotProvider, readTheme: readTheme)
        self.readWindowFrame = readWindowFrame
        self.readScreens = readScreens
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width,
            height: PanelLayout.height(resultCount: sessions.count)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        model.onDismiss = { [weak self] focusRex in self?.dismiss(focusRex: focusRex) }
        model.$theme.dropFirst().sink { [weak self] theme in self?.apply(theme: theme) }.store(in: &subscriptions)
        model.$keymap.removeDuplicates().sink { [weak self] keymap in
            guard let self else { return }
            keyRuntime.reset(keymap: keymap)
            model.keyModes = keyRuntime.modes
        }.store(in: &subscriptions)
        Publishers.CombineLatest(model.$results, model.$error).dropFirst().sink { [weak self] entries, error in
            self?.resize(resultCount: entries.count, hasError: error != nil)
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification).sink { [weak self] event in
            guard let self, self.panel.isVisible || self.positioningTask != nil,
                  let application = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.activationPolicy == .regular,
                  !self.isPresentationApplication(application) else { return }
            self.dismissForOutsideInteraction("Application activated: \(application.bundleIdentifier ?? String(application.processIdentifier))")
        }.store(in: &subscriptions)
        apply(theme: model.theme)
        if let picker { panel.makeFirstResponder(picker.searchField) }
    }

    func toggle(open: () -> Bool) -> Bool {
        guard !model.isConnecting else { return false }
        if panel.isVisible || positioningTask != nil {
            dismiss(focusRex: true)
            return true
        }
        return open()
    }

    func prepare(service: ReshService, snapshot: RexSnapshot, recentSessionIDs: [String] = [], currentSessionID: String? = nil) {
        let pendingQuery = model.isOpening ? model.query : nil
        let previousPID = rexAppPID
        rexAppPID = snapshot.rexAppPID
        model.prepare(service: service, sessions: snapshot.sessions, recentSessionIDs: recentSessionIDs,
            rexAppPID: snapshot.rexAppPID, currentSessionID: currentSessionID)
        if let pendingQuery { model.query = pendingQuery }
        if panel.isVisible, positioningTask == nil, rexAppPID != previousPID { updatePosition() }
    }

    func presentLoading() {
        model.beginOpening()
        rexAppPID = nil
        display()
    }

    func present(error: Error, retry: @escaping () -> Void) {
        let pendingQuery = model.isOpening ? model.query : nil
        rexAppPID = nil
        model.failOpening(error, retry: retry)
        if let pendingQuery { model.query = pendingQuery }
        display()
    }

    func show() {
        model.startBackground()
        model.refreshAttention()
        display()
        model.refreshTheme()
    }

    private func display() {
        isDismissing = false
        resize(resultCount: model.results.count, hasError: model.error != nil)
        if panel.isVisible { return }
        guard positioningTask == nil else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        presentationAppPID = frontmost?.processIdentifier
        if let lastScreenID, let screen = readScreens().first(where: { screenID($0) == lastScreenID }) {
            position(on: screen)
            displayPositioned()
        }
        updatePosition()
    }

    private func updatePosition() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let pid = rexAppPID ?? (frontmost?.bundleIdentifier == RexAppMonitor.bundleIdentifier ? frontmost?.processIdentifier : nil)
        let readWindowFrame = self.readWindowFrame
        // Reuse the last display for immediate keyboard focus, then correct it once.
        positioningTask = Task { [weak self] in
            let frame = await Task.detached { readWindowFrame(pid) }.value
            guard !Task.isCancelled, let self else { return }
            self.positioningTask = nil
            if let resolvedPID = self.rexAppPID, resolvedPID != pid {
                self.updatePosition()
                return
            }
            let screens = self.readScreens()
            guard let frame, let index = PanelPlacement.screenIndex(windowFrame: frame, screens: screens.map(\.frame)) else { return }
            let screen = screens[index]
            if !self.panel.isVisible || self.screenID(screen) != self.lastScreenID { self.position(on: screen) }
            if !self.panel.isVisible { self.displayPositioned() }
        }
    }

    private func displayPositioned() {
        keyRuntime.reset()
        if model.keyModes != keyRuntime.modes { model.keyModes = keyRuntime.modes }
        stopEventMonitoring()
        themeTimer?.invalidate()
        panel.makeKeyAndOrderFront(nil)
        picker?.updateModifiers(NSEvent.modifierFlags)
        if let picker { panel.makeFirstResponder(picker.searchField) }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                self.handleClick(event)
                return event
            default: break
            }
            guard self.panel.isKeyWindow else { return event }
            if event.type == .flagsChanged {
                self.picker?.updateModifiers(event.modifierFlags)
                return event
            }
            guard event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handleClick(event)
        }
        themeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.refreshTheme()
                self?.model.refreshAttention()
            }
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
        let flags: UInt8 = (modifiers.contains(.command) ? 1 : 0) | (modifiers.contains(.control) ? 2 : 0)
            | (modifiers.contains(.option) ? 4 : 0) | (modifiers.contains(.shift) ? 8 : 0)
        let decision = keyRuntime.handle(code: event.keyCode, character: event.characters(byApplyingModifiers: []),
            modifiers: flags, isRepeat: event.isARepeat)
        if model.keyModes != keyRuntime.modes { model.keyModes = keyRuntime.modes }
        switch decision {
        case .passThrough: return false
        case .consumed: return true
        case let .action(shortcut): perform(shortcut)
        case let .invoke(invocation): model.performRexAction(invocation)
        }
        return true
    }

    func perform(_ shortcut: PanelShortcut) {
        switch shortcut {
        case let .scope(scope): model.changeScope(scope)
        case let .move(delta): model.move(delta)
        case .open: model.openSelection()
        case let .openResult(number): model.openResult(number)
        case .create: model.createSession()
        case .pin: model.togglePin()
        case .dismiss: if !model.isConnecting { dismiss(focusRex: true) }
        case .delete: model.deleteSelection()
        case .last: model.openPreviousSession()
        case .nextSource: model.cycleSource(1)
        case .previousSource: model.cycleSource(-1)
        }
    }

    private func resize(resultCount: Int, hasError: Bool) {
        var frame = panel.frame
        let height = PanelLayout.height(resultCount: resultCount, hasError: hasError)
        guard height != frame.height else { return }
        frame.origin.y = frame.maxY - height // Keep the search field stationary.
        frame.size.height = height
        panel.setFrame(frame, display: panel.isVisible, animate: false)
    }

    private func position(on screen: NSScreen) {
        lastScreenID = screenID(screen)
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = max(visible.minX + 10, min(visible.midX - size.width / 2, visible.maxX - size.width - 10))
        let y = max(visible.minY + 10, min(visible.midY - size.height / 2 + 65, visible.maxY - size.height - 10))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func windowDidResignKey(_ notification: Notification) {
        // System permission prompts can take focus repeatedly without the user leaving the picker.
        DebugLog.shared.record("Panel lost key window", source: "panel")
        picker?.updateModifiers([])
    }

    func windowDidBecomeKey(_ notification: Notification) {
        picker?.updateModifiers(NSEvent.modifierFlags)
    }

    private func isPresentationApplication(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier == presentationAppPID
            || application.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || application.bundleIdentifier == Self.permissionPromptBundleID
    }

    private func handleClick(_ event: NSEvent) {
        guard panel.isVisible, !isDismissing, !model.isConnecting, NSApp.modalWindow == nil,
              event.windowNumber != panel.windowNumber else { return }
        guard event.windowNumber > 0 else {
            DebugLog.shared.record("Click has no target window", source: "panel")
            return
        }
        // Query only the clicked window. Core Graphics expects raw window IDs, not CFNumber objects.
        var windowID = UnsafeRawPointer(bitPattern: event.windowNumber)
        guard let windowIDs = CFArrayCreate(nil, &windowID, 1, nil),
              let windows = CGWindowListCreateDescriptionFromArray(windowIDs) as? [[String: Any]],
              let pid = windows.first?[kCGWindowOwnerPID as String] as? Int32,
              let application = NSRunningApplication(processIdentifier: pid) else {
            DebugLog.shared.record("Could not identify owner of clicked window \(event.windowNumber)", source: "panel")
            return
        }
        guard application.bundleIdentifier != Self.permissionPromptBundleID else { return }
        dismissForOutsideInteraction("Click in window \(event.windowNumber) (\(application.bundleIdentifier ?? String(pid)))")
    }

    private func dismissForOutsideInteraction(_ reason: String) {
        guard panel.isVisible || positioningTask != nil, !isDismissing, !model.isConnecting, NSApp.modalWindow == nil else { return }
        DebugLog.shared.record(reason, source: "panel")
        dismiss(focusRex: false)
    }

    private func stopEventMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
    }

    func dismiss(focusRex: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        positioningTask?.cancel()
        positioningTask = nil
        keyRuntime.reset()
        DebugLog.shared.record("Hiding panel (focusRex: \(focusRex))", source: "panel")
        onDismiss?()
        stopEventMonitoring()
        themeTimer?.invalidate()
        panel.orderOut(nil)
        picker?.updateModifiers([])
        if focusRex, NSApp.isActive, let rexAppPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != rexAppPID {
            NSRunningApplication(processIdentifier: rexAppPID)?.activate(options: [])
        }
        model.endPresentation()
    }
}

enum PanelPlacement {
    static func windowFrame(rexAppPID: Int32) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        // The list is front-to-back: use the foremost regular window of this Rex app.
        for window in windows where window[kCGWindowOwnerPID as String] as? Int32 == rexAppPID
            && window[kCGWindowLayer as String] as? Int == 0 {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), !frame.isEmpty else { continue }
            return frame
        }
        return nil
    }

    static func screenIndex(windowFrame: CGRect, screens: [CGRect]) -> Int? {
        guard let primary = screens.first else { return nil }
        // Core Graphics uses a top-left origin; AppKit uses a bottom-left origin.
        let frame = CGRect(x: windowFrame.minX, y: primary.maxY - windowFrame.maxY,
            width: windowFrame.width, height: windowFrame.height)
        var selected: Int?
        var largestArea: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let overlap = screen.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largestArea { selected = index; largestArea = area }
        }
        return selected
    }
}
