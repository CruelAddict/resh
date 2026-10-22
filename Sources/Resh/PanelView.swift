import AppKit
import Combine
import ReshCore

private final class SelectionRow: NSTableRowView {
    var color = NSColor.selectedContentBackgroundColor
    override func drawSelection(in dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// AppKit controls keep the picker compact and avoid cold-start SwiftUI layout work.
@MainActor
final class PanelView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let searchField = NSTextField()
    private let model: SearchModel
    private let searchBackground = NSView()
    private let progress = NSProgressIndicator()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private let scopes: [SearchScope] = [.sessions, .all, .directories, .find]
    private var sourceButtons: [NSButton] = []
    private var rows: [Candidate] = []
    private var theme: RexTheme
    private var activeScope: SearchScope = .sessions
    private var hasError = false
    private var isSelecting = false
    private var subscriptions = Set<AnyCancellable>()

    override var isFlipped: Bool { true }

    init(model: SearchModel) {
        self.model = model; self.theme = model.theme
        super.init(frame: NSRect(x: 0, y: 0, width: PanelLayout.width, height: model.panelHeight))
        autoresizingMask = [.width, .height]

        searchBackground.wantsLayer = true
        searchBackground.layer?.cornerRadius = 16
        searchBackground.layer?.borderWidth = 1
        addSubview(searchBackground)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 14)
        searchField.placeholderString = "Search sessions and folders…"
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("resh.search")
        searchBackground.addSubview(searchField)
        progress.style = .spinning
        progress.controlSize = .mini
        progress.isIndeterminate = true
        progress.isDisplayedWhenStopped = false
        searchBackground.addSubview(progress)

        for (index, scope) in scopes.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(sourceClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.focusRingType = .none
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.setAccessibilityIdentifier("resh.scope.\(scope.rawValue)")
            sourceButtons.append(button)
            addSubview(button)
        }

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
        errorLabel.maximumNumberOfLines = 2
        errorLabel.isSelectable = true
        addSubview(errorLabel)
        retry.isBordered = false
        retry.font = .systemFont(ofSize: 11)
        retry.target = self
        retry.action = #selector(retryClicked)
        addSubview(retry)

        bindModel()
        apply(theme: model.theme)
        emptyLabel.stringValue = model.emptyMessage
    }

    required init?(coder: NSCoder) { nil }

    private func bindModel() {
        model.$results.sink { [weak self] entries in
            guard let self else { return }
            rows = entries
            table.reloadData()
            selectRow(model.selection)
            emptyLabel.isHidden = !entries.isEmpty
            needsLayout = true
        }.store(in: &subscriptions)
        model.$selection.sink { [weak self] in self?.selectRow($0) }.store(in: &subscriptions)
        model.$scope.sink { [weak self] scope in
            self?.activeScope = scope
            self?.updateSources()
        }.store(in: &subscriptions)
        model.$query.sink { [weak self] query in
            if self?.searchField.stringValue != query { self?.searchField.stringValue = query }
        }.store(in: &subscriptions)
        model.$error.sink { [weak self] error in
            self?.hasError = error != nil
            self?.errorLabel.stringValue = error ?? ""
            self?.errorLabel.isHidden = error == nil
            self?.retry.isHidden = error == nil
            self?.needsLayout = true
        }.store(in: &subscriptions)
        Publishers.CombineLatest(model.$isLoading, model.$isConnecting).sink { [weak self] loading, connecting in
            if loading || connecting { self?.progress.startAnimation(nil) }
            else { self?.progress.stopAnimation(nil) }
        }.store(in: &subscriptions)
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                emptyLabel.stringValue = model.emptyMessage
            }
        }.store(in: &subscriptions)
    }

    func apply(theme: RexTheme) {
        self.theme = theme
        searchBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(theme.isDark ? 0.12 : 0.03).cgColor
        searchBackground.layer?.borderColor = theme.foreground.nsColor.withAlphaComponent(0.2).cgColor
        searchField.textColor = theme.foreground.nsColor
        searchField.placeholderAttributedString = NSAttributedString(string: "Search sessions and folders…",
            attributes: [.foregroundColor: theme.foreground.nsColor.withAlphaComponent(0.45), .font: NSFont.systemFont(ofSize: 14)])
        emptyLabel.textColor = theme.foreground.nsColor.withAlphaComponent(0.5)
        updateSources()
        table.reloadData()
        selectRow(model.selection)
        (searchField.currentEditor() as? NSTextView)?.insertionPointColor = theme.accent.nsColor
    }

    private func updateSources() {
        for (index, button) in sourceButtons.enumerated() {
            let scope = scopes[index], selected = scope == activeScope
            let text = NSMutableAttributedString(string: scope.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: selected ? .medium : .regular),
                .foregroundColor: theme.foreground.nsColor.withAlphaComponent(selected ? 1 : 0.55),
            ])
            text.append(NSAttributedString(string: "  " + scope.shortcut, attributes: [
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
        searchField.frame = NSRect(x: 10, y: 7, width: width - 58, height: 19)
        progress.frame = NSRect(x: width - 45, y: 10, width: 12, height: 12)
        var x: CGFloat = 8
        for button in sourceButtons {
            let size = ceil(button.attributedTitle.size().width) + 14
            button.frame = NSRect(x: x, y: PanelLayout.sourcesTop, width: size, height: PanelLayout.sourcesHeight)
            x += size + 4
        }
        let errorHeight: CGFloat = hasError ? 44 : 0
        errorLabel.frame = NSRect(x: 14, y: PanelLayout.listTop, width: width - 80, height: errorHeight)
        retry.frame = NSRect(x: width - 58, y: PanelLayout.listTop + 8, width: 44, height: 24)
        let y = PanelLayout.listTop + errorHeight, listHeight = PanelLayout.listHeight(resultCount: rows.count)
        scroll.frame = NSRect(x: padding, y: y, width: width - padding * 2, height: listHeight)
        table.tableColumns.first?.width = scroll.contentSize.width
        emptyLabel.frame = NSRect(x: 14, y: y + 5, width: width - 28, height: 19)
    }

    var edgeInsets: (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        (searchBackground.frame.minY, bounds.height - scroll.frame.maxY,
         scroll.frame.minX, bounds.width - scroll.frame.maxX)
    }
    var sectionGaps: (searchToSources: CGFloat, sourcesToList: CGFloat) {
        guard let source = sourceButtons.first else { return (-1, -1) }
        return (source.frame.minY - searchBackground.frame.maxY, scroll.frame.minY - source.frame.maxY)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("entry.cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingMiddle
            label.autoresizingMask = [.width]
            cell.textField = label
            cell.addSubview(label)
        }
        cell.textField?.frame = NSRect(x: 8, y: 5, width: max(0, tableView.bounds.width - 16), height: 17)
        cell.textField?.stringValue = rows[row].displayTitle
        cell.textField?.textColor = tableView.selectedRow == row ? .white : theme.foreground.nsColor
        cell.setAccessibilityLabel("\(rows[row].kind == .session ? "Session" : "Folder"), \(rows[row].displayTitle)")
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SelectionRow()
        view.color = theme.selection.nsColor.withAlphaComponent(0.75)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isSelecting, table.selectedRow >= 0 { model.selection = table.selectedRow }
        for row in table.rows(in: table.visibleRect).location..<NSMaxRange(table.rows(in: table.visibleRect)) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField?.textColor =
                row == table.selectedRow ? .white : theme.foreground.nsColor
        }
    }

    private func selectRow(_ row: Int) {
        isSelecting = true
        defer { isSelecting = false }
        if rows.indices.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else { table.deselectAll(nil) }
    }

    func controlTextDidChange(_ notification: Notification) { model.query = searchField.stringValue }
    func controlTextDidBeginEditing(_ notification: Notification) {
        (searchField.currentEditor() as? NSTextView)?.insertionPointColor = theme.accent.nsColor
    }

    @objc private func sourceClicked(_ sender: NSButton) {
        model.changeScope(scopes[sender.tag])
        window?.makeFirstResponder(searchField)
    }
    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        model.selection = table.clickedRow
        model.openSelection()
    }
    @objc private func retryClicked() { model.reload() }
}
