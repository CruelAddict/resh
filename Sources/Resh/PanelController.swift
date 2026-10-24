import AppKit
import Combine
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
    var onDismiss: (() -> Void)?
    private var monitor: Any?
    private var themeTimer: Timer?
    private let attentionConnection: RexAttentionConnection
    private var remoteConnections: [String: (RexHost, RexAttentionConnection)] = [:]
    private var attentionGeneration = 0
    private var subscriptions = Set<AnyCancellable>()
    private var picker: PanelView?
    private var rexAppPID: Int32?
    private var isDismissing = false
    private let defaultConfigurationURL: URL?

    init(service: ReshService, tools: Tools, sessions: [RexSession] = [], configurationURL: URL? = nil,
         snapshotProvider: (any RexSnapshotProviding)? = nil,
         readTheme: @escaping @Sendable (String, Bool) throws -> RexTheme = { try RexTheme.read(rexApp: $0, systemIsDark: $1) }) throws {
        self.model = try SearchModel(service: service, tools: tools, sessions: sessions, configurationURL: configurationURL,
            snapshotProvider: snapshotProvider, readTheme: readTheme)
        self.attentionConnection = RexAttentionConnection(tools: tools)
        self.defaultConfigurationURL = configurationURL
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
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        model.onDismiss = { [weak self] focusRex in self?.dismiss(focusRex: focusRex) }
        model.$isConfigurationReady.dropFirst().removeDuplicates().sink { [weak self] ready in
            guard let self, self.panel.isVisible else { return }
            if ready { self.startAttention() }
            else { self.stopAttention() }
        }.store(in: &subscriptions)
        model.$hosts.dropFirst().sink { [weak self] hosts in
            guard let self, self.panel.isVisible, self.model.isConfigurationReady else { return }
            self.updateRemoteConnections(hosts)
        }.store(in: &subscriptions)
        model.$theme.dropFirst().sink { [weak self] theme in self?.apply(theme: theme) }.store(in: &subscriptions)
        Publishers.CombineLatest(model.$results, model.$error).dropFirst().sink { [weak self] entries, error in
            self?.resize(resultCount: entries.count, hasError: error != nil)
        }.store(in: &subscriptions)
        apply(theme: model.theme)
        if let picker { panel.makeFirstResponder(picker.searchField) }
    }

    func prepare(service: ReshService, snapshot: RexSnapshot, recentSessionIDs: [String] = [], configurationURL: URL? = nil) {
        let pendingQuery = model.isOpening ? model.query : nil
        rexAppPID = snapshot.rexAppPID
        model.prepare(service: service, sessions: snapshot.sessions, recentSessionIDs: recentSessionIDs,
            configurationURL: configurationURL ?? defaultConfigurationURL, rexAppPID: snapshot.rexAppPID)
        if let pendingQuery { model.query = pendingQuery }
    }

    func presentLoading() {
        stopAttention()
        model.beginOpening()
        rexAppPID = nil
        display()
    }

    func present(error: Error, retry: @escaping () -> Void) {
        let pendingQuery = model.isOpening ? model.query : nil
        stopAttention()
        model.clear()
        rexAppPID = nil
        model.error = error.localizedDescription
        model.onRetryOpening = retry
        if let pendingQuery { model.query = pendingQuery }
        display()
    }

    func show() {
        display()
        model.loadInitial()
        model.refreshTheme()
    }

    private func startAttention() {
        attentionGeneration += 1
        let attentionRequest = attentionGeneration
        attentionConnection.start(target: model.service.target) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, attentionGeneration == attentionRequest, panel.isVisible else { return }
                model.receiveAttention(result)
            }
        }
        updateRemoteConnections(model.hosts)
    }

    private func updateRemoteConnections(_ hosts: [RexHost]) {
        let ids = Set(hosts.map(\.id))
        for id in Array(remoteConnections.keys) where !ids.contains(id) {
            remoteConnections.removeValue(forKey: id)?.1.stop()
        }
        for host in hosts {
            if remoteConnections[host.id]?.0 == host { continue }
            remoteConnections.removeValue(forKey: host.id)?.1.stop()
            let connection = RexAttentionConnection(tools: model.tools), request = attentionGeneration
            remoteConnections[host.id] = (host, connection)
            connection.start(target: RexTarget(server: host.server)) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, attentionGeneration == request, panel.isVisible,
                          remoteConnections[host.id]?.0 == host else { return }
                    model.receiveAttention(result, host: host)
                }
            }
        }
    }

    private func display() {
        isDismissing = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        themeTimer?.invalidate()
        position()
        panel.makeKeyAndOrderFront(nil)
        if let picker { panel.makeFirstResponder(picker.searchField) }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
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
        let keymap = model.isConfigurationReady ? model.configuration.keymap : ReshConfiguration.defaults.keymap
        guard let shortcut = keymap.action(for: KeyChord(code: event.keyCode,
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
        guard height != frame.height else { return }
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
        guard !model.isConnecting, !model.isPresentingConfirmation, NSApp.modalWindow == nil else { return }
        dismiss(focusRex: false)
    }

    func dismiss(focusRex: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        onDismiss?()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        themeTimer?.invalidate()
        stopAttention()
        panel.orderOut(nil)
        if focusRex, NSApp.isActive, let rexAppPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != rexAppPID {
            NSRunningApplication(processIdentifier: rexAppPID)?.activate(options: [])
        }
        model.clear()
    }

    @discardableResult
    func stopAttention() -> [RexAttentionConnection] {
        attentionGeneration += 1
        let connections = [attentionConnection] + remoteConnections.values.map { $0.1 }
        remoteConnections = [:]
        for connection in connections { connection.stop() }
        return connections
    }
}
