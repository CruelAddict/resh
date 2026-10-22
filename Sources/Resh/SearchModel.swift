import AppKit
import ReshCore
import Combine

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { updateResults(); selection = 0 } }
    @Published private(set) var scope: SearchScope = .sessions
    @Published var selection = 0
    @Published var isLoading = true
    @Published var isConnecting = false
    @Published var error: String?
    @Published var theme: RexTheme
    @Published private(set) var results: [Candidate] = []
    @Published private(set) var configuration = ReshConfiguration.defaults
    private(set) var configurationURL: URL
    private var configurationError: String?
    private var search = FuzzyMatcher([])
    private var sessionSnapshot: [Candidate]?
    private var warnings: [String] = []
    private(set) var service: ReshService
    let tools: Tools
    var loadingTask: Task<Void, Never>?
    var onDismiss: ((Bool) -> Void)?
    var isPresentingConfirmation = false
    private var generation = 0
    private(set) var receivedLiveSnapshot: Bool
    let themeReadMilliseconds: Double

    init(service: ReshService, tools: Tools, sessions: [RexSession]? = nil, configurationURL: URL = ConfigurationFile.url()) {
        self.service = service; self.tools = tools
        self.configurationURL = configurationURL
        receivedLiveSnapshot = sessions != nil
        let themeStarted = ProcessInfo.processInfo.systemUptime
        theme = RexTheme.read(rexApp: tools.rexApp, systemIsDark: Self.systemIsDark)
        themeReadMilliseconds = (ProcessInfo.processInfo.systemUptime - themeStarted) * 1000
        if let sessions {
            sessionSnapshot = ReshService.candidates(from: sessions)
            scope = configuration.initialSource
            showAvailableEntries()
            isLoading = false
        }
    }
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    var selected: Candidate? { results.indices.contains(selection) ? results[selection] : nil }
    var sessionCount: Int { sessionSnapshot?.count ?? 0 }
    var folderCount: Int { search.entries.lazy.filter { $0.kind != .session }.count }
    var panelHeight: CGFloat { PanelLayout.height(resultCount: results.count, hasError: error != nil) }
    var emptyMessage: String {
        if isLoading { return "Loading…" }
        if !query.isEmpty { return "No matches" }
        if let warning = warnings.first, configuration.source(scope)?.kind != .sessions { return warning }
        return configuration.source(scope)?.kind == .sessions ? "No sessions" : "No folders or projects"
    }

    func loadInitial() {
        load(reloadConfiguration: true, resetScope: true)
    }

    func prepare(service: ReshService, sessions: [RexSession]?, configurationURL: URL? = nil) {
        clear()
        if let configurationURL, configurationURL != self.configurationURL {
            self.configurationURL = configurationURL
            configuration = .defaults
            configurationError = nil
        }
        self.service = service
        receivedLiveSnapshot = sessions != nil
        if let sessions {
            sessionSnapshot = ReshService.candidates(from: sessions)
            scope = configuration.initialSource
            showAvailableEntries()
            isLoading = false
        }
    }

    func clear() {
        generation += 1
        loadingTask?.cancel(); loadingTask = nil
        sessionSnapshot = nil; search = FuzzyMatcher([]); warnings = []
        query = ""; scope = .sessions; selection = 0
        isLoading = false; isConnecting = false; error = nil
        updateResults()
    }

    func reload() { load(reloadConfiguration: true, refreshSessions: true) }

    private func updateResults() {
        let updated = search.filter(query: query)
        if updated != results { results = updated }
        if !results.indices.contains(selection) { selection = 0 }
    }

    private func showAvailableEntries() {
        search = FuzzyMatcher(SourceLoader(tools: tools).availableEntries(scope,
            configuration: configuration, sessions: sessionSnapshot ?? []))
        warnings = []
        updateResults()
    }

    private func load(reloadConfiguration: Bool = false, resetScope: Bool = false, refreshSessions: Bool = false) {
        generation += 1
        loadingTask?.cancel()
        let request = generation, url = configurationURL
        error = configurationError
        if !reloadConfiguration {
            showAvailableEntries()
            if configuration.source(scope)?.kind == .sessions, sessionSnapshot != nil {
                isLoading = false; loadingTask = nil
                return
            }
        }
        isLoading = true
        loadingTask = Task {
            if reloadConfiguration {
                let worker = Task.detached { try ConfigurationFile.load(url) }
                do {
                    let updated = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard generation == request else { return }
                    if updated != configuration { configuration = updated }
                    configurationError = nil
                } catch {
                    guard generation == request else { return }
                    configurationError = error.localizedDescription
                }
                if resetScope || configuration.source(scope) == nil { scope = configuration.initialSource }
                error = configurationError
                showAvailableEntries()
            }
            do {
                if (refreshSessions || sessionSnapshot == nil) && configuration.includesSessions(scope) {
                    let sessions = try await service.sessionCandidates()
                    guard generation == request else { return }
                    sessionSnapshot = sessions
                    showAvailableEntries()
                }
                let loader = SourceLoader(tools: tools), sessions = sessionSnapshot ?? []
                let source = scope, configuration = configuration
                let worker = Task.detached {
                    let result = try loader.load(source, configuration: configuration, sessions: sessions)
                    return (FuzzyMatcher(result.entries), result.warnings)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard generation == request else { return }
                search = result.0
                warnings = result.1
                updateResults()
            } catch {
                guard generation == request else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            isLoading = false; selection = 0
        }
    }
    func changeScope(_ scope: SearchScope) {
        guard !isConnecting, self.scope != scope else { return }
        guard configuration.source(scope) != nil else { return }
        self.scope = scope; selection = 0; error = configurationError
        load()
    }
    func cycleSource(_ delta: Int) {
        let sources = configuration.visibleSources.map(\.id)
        guard let index = sources.firstIndex(of: scope), !sources.isEmpty else { return }
        changeScope(sources[(index + delta + sources.count) % sources.count])
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
