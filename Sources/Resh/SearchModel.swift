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
    @Published private(set) var isOpening = false
    @Published private(set) var isConfigurationReady = true
    @Published var error: String?
    @Published private(set) var diagnostic: String?
    @Published var theme: RexTheme
    @Published private(set) var results: [Candidate] = []
    @Published private(set) var attentionSessionIDs = Set<String>()
    @Published private(set) var configuration = ReshConfiguration.defaults
    private(set) var configurationURL: URL?
    private(set) var configurationError: String?
    private var search = FuzzyMatcher([])
    private var sessionSnapshot: [Candidate] = []
    private var sourceSnapshots: [SearchScope: [Candidate]] = [:]
    private var rexAppPID: Int32?
    private let snapshotProvider: any RexSnapshotProviding
    private let readPreferences: @Sendable () -> [String: Any]
    private let readTheme: @Sendable (String, Bool) throws -> RexTheme
    private var diagnostics: [String: String] = [:]
    private(set) var service: ReshService
    let tools: Tools
    var loadingTask: Task<Void, Never>?
    private(set) var attentionTask: Task<Void, Never>?
    private var themeTask: Task<Void, Never>?
    private var themeTaskID: UUID?
    private var attentionRecords: [RexAttentionRecord] = []
    var onDismiss: ((Bool) -> Void)?
    var onRetryOpening: (() -> Void)?
    var isPresentingConfirmation = false
    private var generation = 0

    init(service: ReshService, tools: Tools, sessions: [RexSession] = [], configurationURL: URL? = nil,
         snapshotProvider: (any RexSnapshotProviding)? = nil,
         readTheme: @escaping @Sendable (String, Bool) throws -> RexTheme = { try RexTheme.read(rexApp: $0, systemIsDark: $1) },
         readPreferences: @escaping @Sendable () -> [String: Any] = { RexTheme.preferences(keys: ["Workspace.programActivitySeen"]) }) throws {
        self.service = service; self.tools = tools
        self.configurationURL = configurationURL
        self.snapshotProvider = snapshotProvider ?? RexDataConnection(tools: tools)
        self.readPreferences = readPreferences
        self.readTheme = readTheme
        self.theme = try readTheme(tools.rexApp, Self.systemIsDark)
        sessionSnapshot = ReshService.candidates(from: sessions)
        scope = configuration.initialSource
        showAvailableEntries()
        isLoading = false
    }
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    var selected: Candidate? { results.indices.contains(selection) ? results[selection] : nil }
    var sessionCount: Int { sessionSnapshot.count }
    var displayedError: String? {
        let messages = [error, diagnostic].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    var panelHeight: CGFloat { PanelLayout.height(resultCount: results.count, hasError: displayedError != nil) }
    var canRetry: Bool { configurationError == nil }
    var emptyMessage: String {
        if isOpening { return "Loading sessions…" }
        if isLoading { return "Loading…" }
        if !query.isEmpty { return "No matches" }
        return configuration.source(scope)?.kind == .sessions ? "No sessions" : "No folders or projects"
    }

    func loadInitial() {
        load(reloadConfiguration: true, resetScope: true)
    }

    func beginOpening() {
        clear()
        isOpening = true
        isLoading = true
    }

    func prepare(service: ReshService, sessions: [RexSession], configurationURL: URL? = nil, rexAppPID: Int32? = nil) {
        clear()
        if configurationURL != self.configurationURL {
            self.configurationURL = configurationURL
            configuration = .defaults
            configurationError = nil
        }
        self.service = service
        self.rexAppPID = rexAppPID
        sessionSnapshot = ReshService.candidates(from: sessions)
        scope = configuration.initialSource
        showAvailableEntries()
        isLoading = false
    }

    func clear() {
        generation += 1
        loadingTask?.cancel(); loadingTask = nil
        attentionTask?.cancel(); attentionTask = nil
        themeTask?.cancel(); themeTask = nil; themeTaskID = nil
        attentionRecords = []; attentionSessionIDs = []
        sessionSnapshot = []; search = FuzzyMatcher([])
        sourceSnapshots = [:]
        rexAppPID = nil
        diagnostics = [:]; diagnostic = nil
        configurationError = nil
        isConfigurationReady = false
        isOpening = false
        onRetryOpening = nil
        query = ""; scope = .sessions; selection = 0
        isLoading = false; isConnecting = false; error = nil
        updateResults()
    }

    func reload() {
        if let onRetryOpening { onRetryOpening(); return }
        load(reloadConfiguration: true, refreshSessions: true)
    }

    private func updateResults() {
        let updated = search.filter(query: query)
        if updated != results { results = updated }
        if !results.indices.contains(selection) { selection = 0 }
    }

    private func showAvailableEntries() {
        refreshEntries()
        reportDiagnostic(nil, source: "source")
    }

    private func refreshEntries() {
        let selectedID = selected?.id, previousSelection = selection
        let entries = SourceLoader(tools: tools).availableEntries(scope,
            configuration: configuration, sessions: sessionSnapshot, snapshots: sourceSnapshots)
        if entries != search.entries { search = FuzzyMatcher(entries, reusing: search) }
        updateResults()
        selection = selectedID.flatMap { id in results.firstIndex { $0.id == id } }
            ?? min(previousSelection, max(0, results.count - 1))
    }

    private func updateSessions(_ sessions: [RexSession]) {
        let updated = ReshService.candidates(from: sessions)
        guard updated != sessionSnapshot else { return }
        sessionSnapshot = updated
        if isConfigurationReady { refreshEntries() }
    }

    private func load(reloadConfiguration: Bool = false, resetScope: Bool = false, refreshSessions: Bool = false) {
        generation += 1
        loadingTask?.cancel()
        sourceSnapshots = [:]
        let request = generation, url = configurationURL
        error = configurationError
        if reloadConfiguration { isConfigurationReady = false }
        if !reloadConfiguration {
            showAvailableEntries()
            if configuration.source(scope)?.kind == .sessions {
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
                    isConfigurationReady = true
                } catch {
                    guard generation == request else { return }
                    let path = (url ?? ConfigurationFile.url()).path
                    if !FileManager.default.fileExists(atPath: path) {
                        configurationError = "Config file not found: \(path)\nCorrect --config in Rex's init.lua and reload the Rex config."
                    } else {
                        configurationError = error.localizedDescription + "\nFix this file, then reopen resh."
                    }
                    search = FuzzyMatcher([])
                    updateResults()
                    self.error = configurationError
                    isLoading = false
                    return
                }
                if resetScope || configuration.source(scope) == nil { scope = configuration.initialSource }
                error = configurationError
                showAvailableEntries()
            }
            do {
                if refreshSessions {
                    let provider = snapshotProvider, rexAppPID = rexAppPID
                    let target = rexAppPID == nil ? service.target : RexTarget(server: service.target.server)
                    let snapshot = try await Task.detached { try provider.snapshot(target: target, rexAppPID: rexAppPID) }.value
                    guard generation == request else { return }
                    service = ReshService(client: RexClient(tools: tools,
                        target: RexTarget(clientID: snapshot.client, server: target.server)))
                    sessionSnapshot = ReshService.candidates(from: snapshot.sessions)
                    showAvailableEntries()
                }
                let loader = SourceLoader(tools: tools), sessions = sessionSnapshot
                let source = scope, configuration = configuration
                let worker = Task.detached {
                    let result = try loader.load(source, configuration: configuration, sessions: sessions)
                    return (FuzzyMatcher(result.entries), result)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard generation == request else { return }
                search = result.0
                sourceSnapshots = result.1.snapshots
                reportDiagnostic(result.1.warnings.isEmpty ? nil : ReshError(result.1.warnings.joined(separator: "\n")), source: "source")
                refreshEntries()
            } catch {
                guard generation == request else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            isLoading = false
        }
    }
    func changeScope(_ scope: SearchScope) {
        guard isConfigurationReady, !isConnecting, self.scope != scope else { return }
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
        guard isConfigurationReady, !isConnecting, let candidate = selected else { return }
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
        guard isConfigurationReady, !isConnecting, let selected, let sessionID = selected.sessionID else { return }
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
                let warning = try await service.delete(sessionID: sessionID)
                sessionSnapshot.removeAll { $0.sessionID == sessionID }
                refreshEntries()
                isConnecting = false
                reportDiagnostic(warning.map { ReshError($0) }, source: "registry")
            } catch { self.error = error.localizedDescription; isConnecting = false }
        }
    }
    func refreshTheme() {
        guard themeTask == nil else { return }
        let app = tools.rexApp, dark = Self.systemIsDark, reader = readTheme, request = generation
        let id = UUID()
        themeTaskID = id
        themeTask = Task {
            defer { if themeTaskID == id { themeTask = nil; themeTaskID = nil } }
            do {
                let updated = try await Task.detached { try reader(app, dark) }.value
                guard generation == request else { return }
                if updated != theme { theme = updated }
                reportDiagnostic(nil, source: "theme")
            } catch {
                guard generation == request else { return }
                reportDiagnostic(error, source: "theme")
            }
        }
    }

    func reportDiagnostic(_ error: Error?, source: String) {
        diagnostics[source] = error?.localizedDescription
        let messages = diagnostics.keys.sorted().compactMap { diagnostics[$0] }
        diagnostic = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func receiveAttention(_ result: Result<RexAttentionUpdate, Error>) {
        switch result {
        case let .success(.records(records)): updateAttention(records)
        case let .success(.sessions(sessions)): updateSessions(sessions)
        case let .failure(error):
            attentionTask?.cancel(); attentionTask = nil
            attentionRecords = []; attentionSessionIDs = []
            reportDiagnostic(error, source: "attention")
        }
    }

    func updateAttention(_ records: [RexAttentionRecord]) {
        reportDiagnostic(nil, source: "attention")
        attentionRecords = records
        refreshAttention()
    }

    func refreshAttention() {
        attentionTask?.cancel()
        let records = attentionRecords, request = generation, preferences = readPreferences
        guard !records.isEmpty else {
            attentionSessionIDs = []; attentionTask = nil
            return
        }
        attentionTask = Task {
            do {
                let unseen = try await Task.detached {
                    try RexAttention.unseenSessionIDs(in: records, preferences: preferences())
                }.value
                guard !Task.isCancelled, generation == request else { return }
                if attentionSessionIDs != unseen { attentionSessionIDs = unseen }
                reportDiagnostic(nil, source: "attention")
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                attentionSessionIDs = []
                reportDiagnostic(error, source: "attention")
            }
        }
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
