import AppKit
import Combine
import QuartzCore
import ReshCore

private final class SelectionRow: NSTableRowView {
    var color = NSColor.selectedContentBackgroundColor
    override func drawSelection(in dirtyRect: NSRect) {
        color.setFill()
        let radius = PanelLayout.controlCornerRadius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

@MainActor
private final class AttentionIndicatorView: NSView {
    var color = NSColor.controlAccentColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.35, dy: 1.35))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        color.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: color.blended(withFraction: 0.35, of: .white) ?? color,
            ending: color.blended(withFraction: 0.1, of: .black) ?? color)?.draw(in: circle, angle: -90)
        NSColor.black.withAlphaComponent(0.85).setStroke()
        circle.lineWidth = 0.7
        circle.stroke()
    }
}

@MainActor
final class SessionCellView: NSTableCellView {
    private let attention = AttentionIndicatorView()
    private let working = NSProgressIndicator()
    let agentIcon = NSImageView()
    let hostLabel = NSTextField(labelWithString: "")
    let pin = NSImageView()
    private let currentSession = NSImageView()
    let shortcutLabel = NSTextField(labelWithString: "")
    let pinHintLabel = NSTextField(labelWithString: "")
    let closeHintLabel = NSTextField(labelWithString: "")
    private var hostColumnWidth: CGFloat = 0
    private var shortcutColumnWidth: CGFloat = 24
    private var representedID: String?
    private var isPinned = false
    private var animatesPinChange = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        textField = label
        addSubview(label)
        agentIcon.imageScaling = .scaleProportionallyUpOrDown
        agentIcon.setAccessibilityElement(false)
        agentIcon.isHidden = true
        addSubview(agentIcon)
        attention.setAccessibilityElement(false)
        attention.isHidden = true
        addSubview(attention)
        working.style = .spinning
        working.controlSize = .mini
        working.isIndeterminate = true
        working.isDisplayedWhenStopped = false
        working.isHidden = true
        working.setAccessibilityElement(false)
        addSubview(working)
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pin.imageScaling = .scaleProportionallyUpOrDown
        pin.setAccessibilityElement(false)
        pin.wantsLayer = true
        pin.alphaValue = 0
        addSubview(pin)
        currentSession.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        currentSession.imageScaling = .scaleProportionallyUpOrDown
        currentSession.setAccessibilityElement(false)
        currentSession.isHidden = true
        addSubview(currentSession)
        shortcutLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.alignment = .right
        shortcutLabel.isHidden = true
        addSubview(shortcutLabel)
        for hint in [pinHintLabel, closeHintLabel] {
            hint.font = shortcutLabel.font
            hint.alignment = .right
            hint.isHidden = true
            addSubview(hint)
        }
        hostLabel.font = .systemFont(ofSize: 11)
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.alignment = .right
        hostLabel.isHidden = true
        addSubview(hostLabel)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ candidate: Candidate, needsAttention: Bool, color: NSColor, textColor: NSColor,
                   showHost: Bool = false, hostWidth: CGFloat = 0, isPinned: Bool = false,
                   isCurrent: Bool = false, shortcut: String = "", shortcutWidth: CGFloat = 24,
                   pinHint: String = "", closeHint: String = "", isWorking: Bool = false, agentImage: NSImage? = nil) {
        let pinned = candidate.kind == .session && isPinned
        if representedID != candidate.id {
            animatesPinChange = false
            pin.layer?.removeAnimation(forKey: "pin")
        } else if self.isPinned != pinned {
            layoutSubtreeIfNeeded()
            animatesPinChange = window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        representedID = candidate.id
        self.isPinned = pinned
        let agent = candidate.kind == .agent ? candidate.agent : nil
        textField?.stringValue = agent?.title ?? candidate.displayTitle
        textField?.textColor = textColor
        agentIcon.image = agentImage
        agentIcon.isHidden = agent == nil
        agentIcon.contentTintColor = textColor
        agentIcon.toolTip = agent?.app
        attention.isHidden = !needsAttention || (candidate.kind != .session && candidate.kind != .agent)
        attention.color = color
        let spins = candidate.kind == .agent && isWorking && attention.isHidden
        if spins != !working.isHidden {
            working.isHidden = !spins
            if spins { working.startAnimation(nil) }
            else { working.stopAnimation(nil) }
        }
        let hintColor = textColor.withAlphaComponent(0.55)
        pin.contentTintColor = hintColor
        currentSession.contentTintColor = textColor
        currentSession.isHidden = !isCurrent
        shortcutColumnWidth = shortcutWidth
        shortcutLabel.stringValue = shortcut
        shortcutLabel.textColor = hintColor
        shortcutLabel.isHidden = isCurrent || shortcut.isEmpty
        pinHintLabel.stringValue = pinHint
        closeHintLabel.stringValue = closeHint
        for hint in [pinHintLabel, closeHintLabel] {
            hint.textColor = hintColor
            hint.isHidden = hint.stringValue.isEmpty
        }
        hostColumnWidth = hostWidth
        hostLabel.stringValue = agent.map { $0.sessionTitle + " | " + candidate.hostLabel } ?? candidate.hostLabel
        hostLabel.textColor = hintColor
        hostLabel.isHidden = !showHost
        toolTip = !attention.isHidden ? "Unread result or action required in this \(candidate.kind == .agent ? "pane" : "session")"
            : spins ? "Agent working" : nil
        let accessibleTitle = agent.map { "\($0.sessionTitle), \($0.app), \($0.title)" } ?? candidate.displayTitle
        setAccessibilityLabel("\(candidate.kind == .agent ? "Agent" : candidate.kind == .session ? "Session" : "Folder"), \(accessibleTitle)"
            + (showHost || agent != nil ? ", \(candidate.hostLabel)" : "")
            + (pinned ? ", pinned" : "")
            + (isCurrent ? ", current session" : "")
            + (attention.isHidden ? "" : ", unread activity")
            + (spins ? ", working" : ""))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let textField else { return }
        let hostWidth = hostLabel.isHidden ? 0 : min(bounds.width * 0.3,
            max(hostColumnWidth, ceil(hostLabel.cell?.cellSize.width ?? 0)))
        // Smaller metadata text shares the title's baseline, not its frame origin.
        let titleBaselineOffset = textField.firstBaselineOffsetFromTop
        hostLabel.frame = NSRect(x: bounds.width - 8 - hostWidth,
            y: 5 + hostLabel.firstBaselineOffsetFromTop - titleBaselineOffset, width: hostWidth, height: 17)
        shortcutLabel.frame = NSRect(x: 8,
            y: 5 + shortcutLabel.firstBaselineOffsetFromTop - titleBaselineOffset, width: shortcutColumnWidth, height: 17)
        currentSession.frame = NSRect(x: 8 + (shortcutColumnWidth - 12) / 2, y: 6, width: 12, height: 14)
        let gap: CGFloat = 6
        let titleStart = shortcutLabel.frame.maxX + gap
        pin.frame = NSRect(x: titleStart, y: 6, width: 12, height: 14)
        var trailing = hostLabel.frame.minX - (hostLabel.isHidden ? 0 : gap)
        // Size each item to its text: a wide, right-aligned number field adds
        // invisible padding that makes the preceding gap look much larger.
        for hint in [closeHintLabel, pinHintLabel] {
            let width = hint.stringValue.isEmpty ? 0 : ceil(hint.cell?.cellSize.width ?? 0)
            hint.frame = NSRect(x: trailing - width,
                y: 5 + hint.firstBaselineOffsetFromTop - titleBaselineOffset, width: width, height: 17)
            if width > 0 { trailing = hint.frame.minX - gap }
        }
        var titleX = titleStart + (isPinned ? 18 : 0)
        let titleEnd = trailing - (working.isHidden ? 14 : 18)
        if !agentIcon.isHidden {
            agentIcon.frame = NSRect(x: titleX, y: 6, width: 14, height: 14)
            titleX = agentIcon.frame.maxX + 6
        }
        let available = max(0, titleEnd - titleX)
        // NSTextField's intrinsic width omits NSTextFieldCell's horizontal
        // drawing insets. Using it clips even "resh" despite ample row space.
        let fitting = ceil(textField.cell?.cellSize.width ?? available)
        let width = min(available, fitting)
        let titleFrame = NSRect(x: titleX, y: 5, width: width, height: 17)
        let attentionFrame = NSRect(x: titleFrame.maxX + 5, y: 9, width: 9, height: 9)
        working.frame = NSRect(x: titleFrame.maxX + 4, y: 7, width: 12, height: 12)
        if animatesPinChange {
            animatesPinChange = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                textField.animator().frame = titleFrame
                attention.animator().frame = attentionFrame
                pin.animator().alphaValue = isPinned ? 1 : 0
            }
            if isPinned {
                let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
                pulse.values = [0.85, 1.12, 1]
                pulse.duration = 0.16
                pin.layer?.add(pulse, forKey: "pin")
            }
        } else {
            textField.frame = titleFrame
            attention.frame = attentionFrame
            pin.alphaValue = isPinned ? 1 : 0
        }
    }
}

@MainActor
private final class NewSessionCellView: NSTableCellView {
    private let icon = NSImageView()
    private let shortcut = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private var hostColumnWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "New Session")
        label.font = .systemFont(ofSize: 13)
        textField = label
        addSubview(label)
        icon.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        addSubview(icon)
        shortcut.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shortcut.alignment = .right
        addSubview(shortcut)
        hostLabel.font = .systemFont(ofSize: 11)
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.alignment = .right
        addSubview(hostLabel)
        setAccessibilityIdentifier("resh.new-session")
        setAccessibilityLabel("New Session")
    }

    required init?(coder: NSCoder) { nil }

    func configure(textColor: NSColor, key: String, host: String, hostWidth: CGFloat) {
        textField?.textColor = textColor
        icon.contentTintColor = textColor
        shortcut.textColor = textColor.withAlphaComponent(0.55)
        shortcut.stringValue = key
        hostLabel.stringValue = host
        hostLabel.textColor = shortcut.textColor
        hostColumnWidth = hostWidth
        setAccessibilityLabel("New Session, \(host)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let textField else { return }
        let titleBaselineOffset = textField.firstBaselineOffsetFromTop
        let hostWidth = min(bounds.width * 0.3, max(hostColumnWidth, ceil(hostLabel.cell?.cellSize.width ?? 0)))
        hostLabel.frame = NSRect(x: bounds.width - 8 - hostWidth,
            y: 5 + hostLabel.firstBaselineOffsetFromTop - titleBaselineOffset, width: hostWidth, height: 17)
        let shortcutWidth = shortcut.stringValue.isEmpty ? 0 : ceil(shortcut.cell?.cellSize.width ?? 0)
        shortcut.frame = NSRect(x: hostLabel.frame.minX - 6 - shortcutWidth,
            y: 5 + shortcut.firstBaselineOffsetFromTop - titleBaselineOffset, width: shortcutWidth, height: 17)
        icon.frame = NSRect(x: 8, y: 5, width: 16, height: 16)
        let trailing = shortcutWidth > 0 ? shortcut.frame.minX : hostLabel.frame.minX
        textField.frame = NSRect(x: 32, y: 5, width: max(0, trailing - 44), height: 17)
    }
}

/// AppKit controls keep the picker compact and avoid cold-start SwiftUI layout work.
@MainActor
final class PanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let searchField = NSTextField()
    private let model: SearchModel
    private let agentIcons: RexAgentIcons
    private let searchBackground = NSView()
    private let createHintLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let errorScroll = NSScrollView()
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private var sources: [SourceDefinition] = []
    private var keymap = Keymap.defaults
    private var keyModes = ["resh"]
    private let sourceScroll = NSScrollView()
    private let sourceContainer = NSView()
    private var sourceButtons: [NSButton] = []
    private var rows: [Candidate] = []
    private var showsNewSession = false
    private var attentionSessionIDs = Set<String>()
    private var attentionAgentIDs = Set<String>()
    private var workingAgentIDs = Set<String>()
    private var pinnedSessionIDs = Set<String>()
    private var currentCandidateID: String?
    private var modifiers: UInt8 = 0
    private var shortcutsVisible = false
    private var shortcutTask: Task<Void, Never>?
    private var showsActions = true
    private var hostColumnWidth: CGFloat = 0
    private var shortcutColumnWidth: CGFloat = 24
    private var showsHosts = false
    private var theme: RexTheme
    private var activeScope: SearchScope = .sessions
    private var isSelecting = false
    private var subscriptions = Set<AnyCancellable>()

    override var isFlipped: Bool { true }

    init(model: SearchModel) {
        self.model = model; self.theme = model.theme
        self.agentIcons = RexAgentIcons(rexApp: model.tools.rexApp)
        self.keymap = model.keymap
        super.init(frame: NSRect(x: 0, y: 0, width: PanelLayout.width, height: model.panelHeight))
        autoresizingMask = [.width, .height]
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))

        searchBackground.wantsLayer = true
        searchBackground.layer?.cornerRadius = PanelLayout.controlCornerRadius
        searchBackground.layer?.borderWidth = 1
        addSubview(searchBackground)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 14)
        searchField.placeholderString = "Filter or create…"
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("resh.search")
        searchBackground.addSubview(searchField)
        createHintLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        createHintLabel.alignment = .right
        createHintLabel.isHidden = true
        searchBackground.addSubview(createHintLabel)
        progress.style = .spinning
        progress.controlSize = .mini
        progress.isIndeterminate = true
        progress.isDisplayedWhenStopped = false
        searchBackground.addSubview(progress)

        sourceScroll.drawsBackground = false
        sourceScroll.hasHorizontalScroller = true
        sourceScroll.autohidesScrollers = true
        sourceScroll.scrollerStyle = .overlay
        sourceScroll.documentView = sourceContainer
        addSubview(sourceScroll)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = PanelLayout.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = table
        addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.lineBreakMode = .byTruncatingTail
        addSubview(emptyLabel)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemOrange
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isSelectable = true
        errorScroll.drawsBackground = false
        errorScroll.hasVerticalScroller = true
        errorScroll.autohidesScrollers = true
        errorScroll.scrollerStyle = .overlay
        errorScroll.borderType = .noBorder
        errorScroll.documentView = errorLabel
        addSubview(errorScroll)
        retry.isBordered = false
        retry.font = .systemFont(ofSize: 11)
        retry.target = self
        retry.action = #selector(retryClicked)
        addSubview(retry)

        bindModel()
        apply(theme: model.theme)
        updateEmptyState()
    }

    required init?(coder: NSCoder) { nil }

    deinit { shortcutTask?.cancel() }

    private func bindModel() {
        model.$keymap.sink { [weak self] keymap in
            guard let self else { return }
            self.keymap = keymap
            updateSources()
            refreshCells()
        }.store(in: &subscriptions)
        model.$keyModes.sink { [weak self] modes in
            guard let self else { return }
            keyModes = modes
            updateSources()
            refreshCells()
        }.store(in: &subscriptions)
        model.$visibleSources.sink { [weak self] sources in
            guard let self else { return }
            self.sources = sources
            for button in sourceButtons { button.removeFromSuperview() }
            sourceButtons = sources.enumerated().map { index, source in
                let button = NSButton(title: "", target: self, action: #selector(self.sourceClicked(_:)))
                button.tag = index; button.isBordered = false; button.focusRingType = .none
                button.isEnabled = self.model.isConfigurationReady
                button.wantsLayer = true
                button.layer?.cornerRadius = min(PanelLayout.controlCornerRadius, PanelLayout.sourcesHeight / 2)
                button.setAccessibilityIdentifier("resh.scope.\(source.id.rawValue)")
                self.sourceContainer.addSubview(button)
                return button
            }
            updateSources()
        }.store(in: &subscriptions)
        model.$results.sink { [weak self] entries in
            guard let self else { return }
            updateRows(entries)
            emptyLabel.isHidden = !entries.isEmpty || showsNewSession || model.configurationError != nil
            needsLayout = true
        }.store(in: &subscriptions)
        model.$selection.sink { [weak self] in
            self?.selectRow($0)
        }.store(in: &subscriptions)
        model.$hosts.sink { [weak self] hosts in
            guard let self else { return }
            showsHosts = !hosts.isEmpty
            hostColumnWidth = (["This Mac"] + hosts.map(\.label)).map {
                ceil(($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 4
            }.max() ?? 0
            table.reloadData()
            selectRow(model.selection)
        }.store(in: &subscriptions)
        model.$attentionSessionIDs.sink { [weak self] sessionIDs in
            guard let self else { return }
            attentionSessionIDs = sessionIDs
            // Status updates must not reload search results or move the selection.
            refreshCells()
        }.store(in: &subscriptions)
        model.$attentionAgentIDs.sink { [weak self] ids in
            self?.attentionAgentIDs = ids
            self?.refreshCells()
        }.store(in: &subscriptions)
        model.$workingAgentIDs.sink { [weak self] ids in
            self?.workingAgentIDs = ids
            self?.refreshCells()
        }.store(in: &subscriptions)
        model.$pinnedSessionIDs.sink { [weak self] ids in
            guard let self else { return }
            pinnedSessionIDs = Set(ids)
            refreshCells()
        }.store(in: &subscriptions)
        model.$currentCandidateID.sink { [weak self] id in
            self?.currentCandidateID = id
            self?.refreshCells()
        }.store(in: &subscriptions)
        model.$scope.sink { [weak self] scope in
            self?.activeScope = scope
            self?.updateSources()
        }.store(in: &subscriptions)
        model.$query.sink { [weak self] query in
            if self?.searchField.stringValue != query { self?.searchField.stringValue = query }
        }.store(in: &subscriptions)
        model.$error.map { $0 ?? "" }.removeDuplicates().sink { [weak self] message in
            guard let self else { return }
            errorLabel.stringValue = message
            errorScroll.isHidden = message.isEmpty
            retry.isHidden = message.isEmpty || !model.canRetry
            emptyLabel.isHidden = !rows.isEmpty || showsNewSession || model.configurationError != nil
            scroll.isHidden = model.configurationError != nil
            needsLayout = true
            layoutSubtreeIfNeeded()
            errorLabel.scrollToVisible(NSRect(x: 0, y: max(0, errorLabel.bounds.maxY - 1), width: 1, height: 1))
        }.store(in: &subscriptions)
        Publishers.CombineLatest3(model.$isLoading, model.$isConnecting, model.$isRemoteLoading).sink { [weak self] loading, connecting, remote in
            guard let self else { return }
            progress.isHidden = !loading && !connecting && !remote
            if progress.isHidden { progress.stopAnimation(nil) }
            else { progress.startAnimation(nil) }
            needsLayout = true
        }.store(in: &subscriptions)
        Publishers.CombineLatest(model.$isOpening, model.$isConnecting).sink { [weak self] opening, connecting in
            guard let self else { return }
            let ready = model.isConfigurationReady
            searchField.isEnabled = ready || opening
            table.isEnabled = ready && !opening
            for button in sourceButtons { button.isEnabled = ready && !opening }
            showsActions = ready && !opening && !connecting
            refreshCells()
            if ready || opening, window?.isKeyWindow == true { window?.makeFirstResponder(searchField) }
        }.store(in: &subscriptions)
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                updateEmptyState()
                refreshCells()
            }
        }.store(in: &subscriptions)
    }

    private func updateEmptyState() {
        let updated = model.offersNewSession
        if showsNewSession != updated {
            showsNewSession = updated
            table.reloadData()
            selectRow(model.selection)
        }
        emptyLabel.stringValue = model.emptyMessage
        emptyLabel.isHidden = !rows.isEmpty || showsNewSession || model.configurationError != nil
        needsLayout = true
    }

    private func refreshCreateHint() {
        let key = keymap.label(for: .create, modifiers: modifiers, modes: keyModes)
        createHintLabel.stringValue = key.isEmpty ? "" : key + "  Create"
        createHintLabel.isHidden = !shortcutsVisible || !showsActions || key.isEmpty || !model.canCreateSession
        needsLayout = true
    }

    func apply(theme: RexTheme) {
        self.theme = theme
        searchBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(theme.isDark ? 0.12 : 0.03).cgColor
        searchBackground.layer?.borderColor = theme.foreground.nsColor.withAlphaComponent(0.2).cgColor
        searchField.textColor = theme.foreground.nsColor
        searchField.placeholderAttributedString = NSAttributedString(string: "Filter or create…",
            attributes: [.foregroundColor: theme.foreground.nsColor.withAlphaComponent(0.45), .font: NSFont.systemFont(ofSize: 14)])
        emptyLabel.textColor = theme.foreground.nsColor.withAlphaComponent(0.5)
        createHintLabel.textColor = theme.foreground.nsColor.withAlphaComponent(0.55)
        updateSources()
        table.reloadData()
        selectRow(model.selection)
        (searchField.currentEditor() as? NSTextView)?.insertionPointColor = theme.accent.nsColor
    }

    private func updateSources() {
        for (index, button) in sourceButtons.enumerated() {
            let source = sources[index], selected = source.id == activeScope
            let text = NSMutableAttributedString(string: source.name, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: selected ? .medium : .regular),
                .foregroundColor: theme.foreground.nsColor.withAlphaComponent(selected ? 1 : 0.55),
            ])
            let shortcut = keymap.label(for: source.id, modes: keyModes)
            text.append(NSAttributedString(string: shortcut.isEmpty ? "" : "  " + shortcut, attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: theme.foreground.nsColor.withAlphaComponent(0.4),
            ]))
            button.attributedTitle = text
            button.layer?.backgroundColor = (selected ? theme.foreground.nsColor.withAlphaComponent(0.1) : .clear).cgColor
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let padding = PanelLayout.outerPadding
        searchBackground.frame = NSRect(x: padding, y: padding, width: width - padding * 2, height: PanelLayout.searchHeight)
        let hintWidth = createHintLabel.isHidden ? 0 : ceil(createHintLabel.cell?.cellSize.width ?? 0)
        let trailing = searchBackground.bounds.width - (progress.isHidden ? 10 : 32)
        createHintLabel.frame = NSRect(x: trailing - hintWidth,
            y: 7 + createHintLabel.firstBaselineOffsetFromTop - searchField.firstBaselineOffsetFromTop, width: hintWidth, height: 19)
        searchField.frame = NSRect(x: 10, y: 7, width: max(0, trailing - 10 - (hintWidth > 0 ? hintWidth + 12 : 0)), height: 19)
        progress.frame = NSRect(x: width - 45, y: 10, width: 12, height: 12)
        sourceScroll.frame = NSRect(x: padding, y: PanelLayout.sourcesTop, width: width - padding * 2, height: PanelLayout.sourcesHeight)
        var x: CGFloat = 0
        for button in sourceButtons {
            let size = ceil(button.attributedTitle.size().width) + 14
            button.frame = NSRect(x: x, y: 0, width: size, height: PanelLayout.sourcesHeight)
            x += size + 4
        }
        sourceContainer.setFrameSize(NSSize(width: max(sourceScroll.contentSize.width, x - 4), height: PanelLayout.sourcesHeight))
        if let index = sources.firstIndex(where: { $0.id == activeScope }) {
            sourceContainer.scrollToVisible(sourceButtons[index].frame)
        }
        let errorHeight: CGFloat = errorScroll.isHidden ? 0 : 44
        errorScroll.frame = NSRect(x: 14, y: PanelLayout.listTop + 8, width: width - 80, height: 28)
        let area = NSRect(x: 0, y: 0, width: errorScroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        errorLabel.frame = NSRect(x: 0, y: 0, width: errorScroll.contentSize.width,
            height: max(28, ceil(errorLabel.cell?.cellSize(forBounds: area).height ?? 0)))
        retry.frame = NSRect(x: width - 58, y: PanelLayout.listTop + 8, width: 44, height: 24)
        let y = PanelLayout.listTop + errorHeight, listHeight = PanelLayout.listHeight(resultCount: rows.count)
        scroll.frame = NSRect(x: padding, y: y, width: width - padding * 2, height: listHeight)
        table.tableColumns.first?.width = scroll.contentSize.width
        emptyLabel.frame = NSRect(x: 14, y: y + 5, width: width - 28, height: 19)
    }

    func updateModifiers(_ flags: NSEvent.ModifierFlags) {
        let updated = KeyChord(code: 0, command: flags.contains(.command), control: flags.contains(.control),
            option: flags.contains(.option), shift: flags.contains(.shift)).modifiers
        let changed = modifiers & 7 != updated & 7
        modifiers = updated
        if changed {
            shortcutTask?.cancel(); shortcutTask = nil
            shortcutsVisible = false
            if updated & 7 != 0 {
                shortcutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(600)) }
                    catch { return }
                    guard !Task.isCancelled, let self else { return }
                    shortcutsVisible = true
                    shortcutTask = nil
                    refreshCells()
                }
            }
        }
        refreshCells()
    }

    private func refreshCells() {
        refreshCreateHint()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shortcutColumnWidth = max(24, (1...9).map {
            ceil((resultShortcut(for: $0) as NSString).size(withAttributes: [.font: font]).width) + 4
        }.max() ?? 0)
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound {
            for row in visible.location..<NSMaxRange(visible) {
                let view = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                if let cell = view as? NewSessionCellView {
                    configure(cell, row: row)
                } else if rows.indices.contains(row), let cell = view as? SessionCellView {
                    configure(cell, row: row)
                }
            }
        }
    }

    private func updateRows(_ entries: [Candidate]) {
        let previous = rows
        rows = entries
        if !entries.isEmpty { showsNewSession = false }
        isSelecting = true
        if let id = model.animatedSessionID, window?.isVisible == true,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let from = previous.firstIndex(where: { $0.id == id }), let to = entries.firstIndex(where: { $0.id == id }),
           from != to, previous.filter({ $0.id != id }) == entries.filter({ $0.id != id }) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                table.beginUpdates()
                table.moveRow(at: from, to: to)
                table.endUpdates()
            }
            selectRow(to)
        } else {
            table.reloadData()
            selectRow(model.selection)
        }
        isSelecting = false
        refreshCells()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count + (showsNewSession ? 1 : 0) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if showsNewSession, row == rows.count {
            let identifier = NSUserInterfaceItemIdentifier("new-session.cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NewSessionCellView ?? NewSessionCellView()
            cell.identifier = identifier
            configure(cell, row: row)
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("entry.cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SessionCellView ?? SessionCellView()
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: NewSessionCellView, row: Int) {
        cell.configure(textColor: table.selectedRow == row ? .white : theme.foreground.nsColor,
            key: keymap.label(for: .create, modes: keyModes), host: model.newSessionHost?.label ?? "This Mac", hostWidth: hostColumnWidth)
    }

    private func resultShortcut(for number: Int) -> String {
        let preferred: UInt8 = modifiers & 7 == 0 ? 1 : modifiers
        let label = keymap.label(for: .openResult(number), modifiers: preferred, modes: keyModes)
        return label.isEmpty ? keymap.label(for: .openResult(number), modes: keyModes) : label
    }

    private func configure(_ cell: SessionCellView, row: Int) {
        let entry = rows[row]
        let selected = table.selectedRow == row
        let pinned = entry.sessionID.map { pinnedSessionIDs.contains($0) } ?? false
        let numbered = rows.indices.filter { rows[$0].id != currentCandidateID }.prefix(9)
        let number = numbered.firstIndex(of: row).map { numbered.distance(from: numbered.startIndex, to: $0) + 1 }
        var pinHint = "", closeHint = ""
        if shortcutsVisible, selected, showsActions, entry.kind == .session {
            let pinKey = keymap.label(for: .pin, modifiers: modifiers, modes: keyModes)
            let closeKey = keymap.label(for: .delete, modifiers: modifiers, modes: keyModes)
            if !pinKey.isEmpty { pinHint = pinKey + (pinned ? "  Unpin" : "  Pin") }
            if !closeKey.isEmpty { closeHint = closeKey + "  Close" }
        }
        cell.configure(entry, needsAttention: (entry.kind == .agent ? attentionAgentIDs : attentionSessionIDs).contains(entry.id),
            color: theme.attentionColor.nsColor, textColor: selected ? .white : theme.foreground.nsColor,
            showHost: selected && (showsHosts || entry.kind == .agent), hostWidth: hostColumnWidth,
            isPinned: pinned,
            isCurrent: entry.id == currentCandidateID,
            shortcut: number.map { resultShortcut(for: $0) } ?? "", shortcutWidth: shortcutColumnWidth,
            pinHint: pinHint, closeHint: closeHint, isWorking: workingAgentIDs.contains(entry.id),
            agentImage: entry.agent.flatMap { agentIcons.image(for: $0.app) })
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SelectionRow()
        view.color = theme.selection.nsColor.withAlphaComponent(0.75)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isSelecting, table.selectedRow >= 0 { model.selection = table.selectedRow }
        refreshCells()
    }

    override func mouseMoved(with event: NSEvent) {
        // Opening or relayout beneath a stationary pointer must preserve the selection.
        guard event.deltaX != 0 || event.deltaY != 0,
              table.isEnabled, !model.isConnecting, !scroll.isHidden else { return }
        let point = table.convert(event.locationInWindow, from: nil)
        guard table.visibleRect.contains(point) else { return }
        let row = table.row(at: point)
        guard row >= 0, row != model.selection else { return }
        model.selection = row
    }

    private func selectRow(_ row: Int) {
        let wasSelecting = isSelecting
        isSelecting = true
        defer { isSelecting = wasSelecting }
        if (0..<numberOfRows(in: table)).contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else { table.deselectAll(nil) }
    }

    func controlTextDidChange(_ notification: Notification) { model.query = searchField.stringValue }
    func controlTextDidBeginEditing(_ notification: Notification) {
        (searchField.currentEditor() as? NSTextView)?.insertionPointColor = theme.accent.nsColor
    }

    @objc private func sourceClicked(_ sender: NSButton) {
        model.changeScope(sources[sender.tag].id)
        window?.makeFirstResponder(searchField)
    }
    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        model.selection = table.clickedRow
        model.openSelection()
    }
    @objc private func retryClicked() { model.retry() }
}
