import AppKit
import ReshCore
import SwiftUI

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var scope: SearchScope = .sessions
    @Published var catalog = Catalog()
    @Published var selection = 0
    @Published var isLoading = true
    @Published var isConnecting = false
    @Published var error: String?
    @Published var theme: RexTheme
    let service: ReshService
    let tools: Tools
    var loadingTask: Task<Void, Never>?
    var onDismiss: ((Bool) -> Void)?
    var isPresentingConfirmation = false
    private var generation = 0

    init(service: ReshService, tools: Tools) {
        self.service = service; self.tools = tools
        theme = RexTheme.read(rexApp: tools.rexApp, systemIsDark: Self.systemIsDark)
    }
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    var results: [Candidate] { FuzzyMatcher.filter(catalog.entries(for: scope), query: query) }
    var selected: Candidate? { results.indices.contains(selection) ? results[selection] : nil }
    var status: String {
        if isConnecting { return "Opening in Rex…" }
        if isLoading { return scope == .find ? "Finding folders…" : "Loading sessions & folders…" }
        if let error { return error }
        if let warning = catalog.warnings.first { return warning }
        if let selected { return selected.kind == .session ? "↵ Switch to session" : "↵ Open folder as a Rex session" }
        return "No matches · try Recent folders or Find folders"
    }

    func reload() {
        generation += 1
        let request = generation, find = scope == .find
        isLoading = true; error = nil
        loadingTask = Task {
            do {
                let loaded = try await service.catalog(find: find)
                guard generation == request else { return }
                catalog = loaded
            } catch {
                guard generation == request else { return }
                self.error = error.localizedDescription
            }
            isLoading = false; selection = 0
        }
    }
    func changeScope(_ scope: SearchScope) {
        guard !isConnecting, self.scope != scope else { return }
        let needsReload = self.scope == .find || scope == .find
        self.scope = scope; selection = 0; error = nil
        if needsReload { reload() }
    }
    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }
    func openSelection() {
        guard !isConnecting, !isLoading, let candidate = selected else { return }
        isConnecting = true; error = nil
        Task {
            do {
                try await service.connect(candidate)
                onDismiss?(true)
            } catch {
                self.error = error.localizedDescription
                isConnecting = false
            }
        }
    }
    func deleteSelection() {
        guard !isConnecting, let selected, let sessionID = selected.sessionID else { return }
        let alert = NSAlert()
        alert.messageText = "Close ‘\(selected.title)’?"
        alert.informativeText = "This closes every terminal and running program in this Rex session. It cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        let destructive = alert.addButton(withTitle: "Close Session")
        destructive.hasDestructiveAction = true
        isPresentingConfirmation = true
        let response = alert.runModal()
        isPresentingConfirmation = false
        guard response == .alertSecondButtonReturn else { return }
        isConnecting = true
        Task {
            do {
                try await service.delete(sessionID: sessionID)
                isConnecting = false; reload()
            } catch { self.error = error.localizedDescription; isConnecting = false }
        }
    }
    func refreshTheme() {
        let updated = RexTheme.read(rexApp: tools.rexApp, systemIsDark: Self.systemIsDark)
        if updated != theme { theme = updated }
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(nsColor: nsColor) }
}
