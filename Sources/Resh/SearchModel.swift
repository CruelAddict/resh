import AppKit
import ReshCore
import Combine

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { updateResults(); selection = 0 } }
    @Published private(set) var scope: SearchScope = .sessions
    @Published var catalog = Catalog()
    @Published var selection = 0
    @Published var isLoading = true
    @Published var isConnecting = false
    @Published var error: String?
    @Published var theme: RexTheme
    @Published private(set) var results: [Candidate] = []
    let service: ReshService
    let tools: Tools
    var loadingTask: Task<Void, Never>?
    var onDismiss: ((Bool) -> Void)?
    var isPresentingConfirmation = false
    private var generation = 0
    private var hasSessions = false
    let receivedLiveSnapshot: Bool
    let themeReadMilliseconds: Double

    init(service: ReshService, tools: Tools, sessions: [RexSession]? = nil) {
        self.service = service; self.tools = tools
        receivedLiveSnapshot = sessions != nil
        let themeStarted = ProcessInfo.processInfo.systemUptime
        theme = RexTheme.read(rexApp: tools.rexApp, systemIsDark: Self.systemIsDark)
        themeReadMilliseconds = (ProcessInfo.processInfo.systemUptime - themeStarted) * 1000
        if let sessions {
            catalog.sessions = ReshService.candidates(from: sessions)
            hasSessions = true
            isLoading = false
            updateResults()
        }
    }
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    var selected: Candidate? { results.indices.contains(selection) ? results[selection] : nil }
    var panelHeight: CGFloat { PanelLayout.height(resultCount: results.count, hasError: error != nil) }
    var emptyMessage: String {
        if isLoading { return "Loading…" }
        if !query.isEmpty { return "No matches" }
        if let warning = catalog.warnings.first, scope != .sessions { return warning }
        return scope == .sessions ? "No sessions" : "No folders"
    }

    func loadInitial() {
        if !hasSessions { load(refreshSessions: true) }
    }

    func reload() { load(refreshSessions: true) }

    private func updateResults() {
        let updated = FuzzyMatcher.filter(catalog.entries(for: scope), query: query)
        if updated != results { results = updated }
        if !results.indices.contains(selection) { selection = 0 }
    }

    private func load(refreshSessions: Bool = false) {
        generation += 1
        let request = generation, find = scope == .find
        let needsSessions = refreshSessions || !hasSessions
        let needsDirectories = scope != .sessions
        isLoading = true; error = nil
        loadingTask = Task {
            do {
                if needsSessions {
                    let sessions = try await service.sessionCandidates()
                    guard generation == request else { return }
                    catalog.sessions = sessions
                    hasSessions = true
                    updateResults()
                }
                if needsDirectories {
                    let folders = try await service.directoryCatalog(find: find)
                    guard generation == request else { return }
                    catalog.directories = folders.directories
                    catalog.warnings = folders.warnings
                    updateResults()
                }
            } catch {
                guard generation == request else { return }
                self.error = error.localizedDescription
            }
            isLoading = false; selection = 0
        }
    }
    func changeScope(_ scope: SearchScope) {
        guard !isConnecting, self.scope != scope else { return }
        generation += 1
        if self.scope == .find || scope == .find { catalog.directories = [] }
        self.scope = scope; selection = 0; error = nil
        updateResults()
        if scope != .sessions || !hasSessions { load() }
        else { isLoading = false }
    }
    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }
    func openSelection() {
        guard !isConnecting, let candidate = selected else { return }
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
        let app = tools.rexApp, dark = Self.systemIsDark
        Task {
            let updated = await Task.detached { RexTheme.read(rexApp: app, systemIsDark: dark) }.value
            if updated != theme { theme = updated }
        }
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
