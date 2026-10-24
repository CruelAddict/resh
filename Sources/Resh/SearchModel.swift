import AppKit
import ReshCore
import Combine

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { updateResults(); selection = 0 } }
    @Published private(set) var scope: SearchScope = .sessions
    @Published var selection = 0
    @Published var isLoading = true
    @Published private(set) var isRemoteLoading = false
    @Published private(set) var hosts: [RexHost] = []
    @Published var isConnecting = false
    @Published private(set) var isOpening = false
    @Published private(set) var isConfigurationReady = true
    @Published var error: String?
    @Published var theme: RexTheme
    @Published private(set) var results: [Candidate] = []
    @Published private(set) var attentionSessionIDs = Set<String>()
    @Published private(set) var configuration = ReshConfiguration.defaults
    @Published private(set) var visibleSources = ReshConfiguration.defaults.visibleSources
    private(set) var configurationURL: URL?
    private(set) var configurationError: String?
    private var search = FuzzyMatcher([])
    private var sessionSnapshot: [Candidate] = []
    private var sessionRanks: [String: Int] = [:]
    private var sourceSnapshots: [SearchScope: [Candidate]] = [:]
    private var hostSessions: [String: [Candidate]] = [:]
    private var hostSources: [String: [SearchScope: [Candidate]]] = [:]
    private var hostFunctions: [String: Set<String>] = [:]
    private var hasHostCatalog = false
    private var pendingHosts = Set<String>()
    private var remoteTasks: [String: Task<Void, Never>] = [:]
    private(set) var hostsTask: Task<Void, Never>?
    private var hostGeneration = 0
    private var remoteRequest = UUID()
    private var rexAppPID: Int32?
    let catalog: SessionStore
    private var configurationWatcher: FileWatcher?
    private var isBackgroundActive = false
    private var isPresented = false
    private var subscriptions = Set<AnyCancellable>()
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
    private var hostAttentionRecords: [String: [RexAttentionRecord]] = [:]
    var onDismiss: ((Bool) -> Void)?
    var onRetryOpening: (() -> Void)?
    var isPresentingConfirmation = false
    private var generation = 0

    init(service: ReshService, tools: Tools, sessions: [RexSession] = [], recentSessionIDs: [String] = [], configurationURL: URL? = nil,
         snapshotProvider: (any RexSnapshotProviding)? = nil,
         readTheme: @escaping @Sendable (String, Bool) throws -> RexTheme = { try RexTheme.read(rexApp: $0, systemIsDark: $1) },
         readPreferences: @escaping @Sendable () -> [String: Any] = { RexTheme.preferences(keys: ["Workspace.programActivitySeen"]) }) throws {
        self.service = service; self.tools = tools
        self.catalog = SessionStore(tools: tools, service: service)
        self.configurationURL = configurationURL
        self.snapshotProvider = snapshotProvider ?? RexDataConnection(tools: tools)
        self.readPreferences = readPreferences
        self.readTheme = readTheme
        do { self.theme = try readTheme(tools.rexApp, Self.systemIsDark) }
        catch {
            self.theme = .fallback(systemIsDark: Self.systemIsDark)
            DebugLog.shared.record(error, source: "theme")
        }
        sessionSnapshot = ReshService.candidates(from: sessions)
        sessionRanks = Dictionary(recentSessionIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        scope = configuration.initialSource
        showAvailableEntries()
        isLoading = false
        catalog.updates.sink { [weak self] result, host in
            self?.receive(result, host: host)
        }.store(in: &subscriptions)
        catalog.$recentSessionIDs.dropFirst().sink { [weak self] history in
            guard let self, let client = self.service.target.clientID else { return }
            updateRecentSessions(history[client] ?? [])
        }.store(in: &subscriptions)
    }
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    var selected: Candidate? { results.indices.contains(selection) ? results[selection] : nil }
    private var allSessions: [Candidate] {
        (sessionSnapshot + hosts.flatMap { hostSessions[$0.id] ?? [] }).enumerated().sorted {
            let left = sessionRanks[$0.element.id] ?? Int.max, right = sessionRanks[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    var sessionCount: Int { allSessions.count }
    var showsHosts: Bool { !hosts.isEmpty }
    var displayedError: String? { error }
    var panelHeight: CGFloat { PanelLayout.height(resultCount: results.count, hasError: displayedError != nil) }
    var canRetry: Bool { configurationError == nil }
    var emptyMessage: String {
        if isOpening { return "Loading sessions…" }
        if isLoading || isRemoteLoading { return "Loading…" }
        if !query.isEmpty { return "No matches" }
        return configuration.source(scope)?.kind == .sessions ? "No sessions" : "No folders or projects"
    }

    func loadInitial() {
        load(reloadConfiguration: true, resetScope: true)
    }

    func startBackground() {
        catalog.start()
        guard !isBackgroundActive else { return }
        isBackgroundActive = true
        watchConfiguration()
        loadInitial()
    }

    @discardableResult
    func stopBackground() -> [RexEventConnection] {
        isBackgroundActive = false
        configurationWatcher?.stop(); configurationWatcher = nil
        generation += 1
        hostGeneration += 1
        hostsTask?.cancel(); hostsTask = nil
        remoteRequest = UUID()
        for task in remoteTasks.values { task.cancel() }
        remoteTasks = [:]
        loadingTask?.cancel(); loadingTask = nil
        attentionTask?.cancel(); attentionTask = nil
        themeTask?.cancel(); themeTask = nil; themeTaskID = nil
        isLoading = false
        return catalog.stop()
    }

    private func watchConfiguration() {
        configurationWatcher?.stop()
        configurationWatcher = FileWatcher(url: configurationURL ?? ConfigurationFile.url()) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, isBackgroundActive else { return }
                load(reloadConfiguration: true, resetScope: !isPresented)
            }
        }
    }

    func configure(target: RexTarget, configurationURL: URL?) {
        let changedServer = service.target.server != target.server
        let changedConfiguration = self.configurationURL != configurationURL
        guard changedServer || changedConfiguration else { return }
        if changedServer {
            clear()
            service = ReshService(client: RexClient(tools: tools, target: target))
            catalog.configure(target: target)
        }
        if changedConfiguration {
            self.configurationURL = configurationURL
            configurationError = nil
            isConfigurationReady = false
        }
        if changedServer { startBackground() }
        else { watchConfiguration(); loadInitial() }
    }

    private func updateRecentSessions(_ recent: [String]) {
        let ranks = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        guard ranks != sessionRanks else { return }
        sessionRanks = ranks
        refreshEntries()
    }

    func beginOpening() {
        isPresented = true
        isOpening = true
        isLoading = true
        error = configurationError
    }

    func prepare(service: ReshService, sessions: [RexSession], recentSessionIDs: [String] = [], rexAppPID: Int32? = nil) {
        if !isOpening { query = ""; selection = 0 }
        isPresented = true
        self.service = service
        self.rexAppPID = rexAppPID
        sessionSnapshot = ReshService.candidates(from: sessions)
        sessionRanks = Dictionary(recentSessionIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        scope = configuration.initialSource
        showAvailableEntries()
        isOpening = false
        isLoading = loadingTask != nil
        onRetryOpening = nil
        if isConfigurationReady, configuration.source(scope)?.kind != .sessions { load(keepingSnapshots: true) }
    }

    func failOpening(_ error: Error, retry: @escaping () -> Void) {
        isOpening = false; isLoading = false
        self.error = configurationError ?? error.localizedDescription
        onRetryOpening = retry
    }

    func endPresentation() {
        isPresented = false
        query = ""; scope = configuration.initialSource; selection = 0
        isOpening = false; isConnecting = false
        isLoading = loadingTask != nil
        error = configurationError
        onRetryOpening = nil
        showAvailableEntries()
    }

    func clear() {
        stopBackground()
        hosts = []; hostSessions = [:]; hostSources = [:]; hostFunctions = [:]
        hasHostCatalog = false
        visibleSources = configuration.visibleSources
        pendingHosts = []
        hostAttentionRecords = [:]; isRemoteLoading = false
        attentionRecords = []; attentionSessionIDs = []
        sessionSnapshot = []; sessionRanks = [:]; search = FuzzyMatcher([])
        sourceSnapshots = [:]
        rexAppPID = nil
        diagnostics = [:]
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
        guard configurationError == nil else {
            search = FuzzyMatcher([])
            updateResults()
            return
        }
        var visible = configuration.visibleSources.filter {
            sourceIsAvailable($0.id, includeSessions: $0.id != .all || $0.kind != .union)
        }
        let needsFallback = !visible.contains { $0.id == scope }
        if needsFallback, !visible.contains(where: { $0.id == .sessions }), let sessions = configuration.source(.sessions) {
            visible.insert(sessions, at: 0)
        }
        if visibleSources != visible { visibleSources = visible }
        if needsFallback, scope != .sessions, isConfigurationReady {
            scope = .sessions
            load()
            return
        }
        let selectedID = selected?.id, previousSelection = selection
        var snapshots = sourceSnapshots
        for host in hosts {
            for (source, entries) in hostSources[host.id] ?? [:] { snapshots[source, default: []] += entries }
        }
        let entries = SourceLoader(tools: tools).availableEntries(scope,
            configuration: configuration, sessions: allSessions, snapshots: snapshots)
        if entries != search.entries {
            DebugLog.shared.record("\(scope.rawValue): \(entries.count) entries from \(hosts.count + 1) hosts", source: "results")
            search = FuzzyMatcher(entries, reusing: search)
        }
        updateResults()
        selection = selectedID.flatMap { id in results.firstIndex { $0.id == id } }
            ?? min(previousSelection, max(0, results.count - 1))
    }

    /// Unknown hosts do not prove a provider is absent. Empty query results do
    /// not affect visibility: an available source may simply have no data yet.
    private func sourceIsAvailable(_ id: SearchScope, includeSessions: Bool = true) -> Bool {
        guard let source = configuration.source(id) else { return false }
        func supports(_ function: String, local: Bool) -> Bool {
            local || !hasHostCatalog || hosts.contains { hostFunctions[$0.id]?.contains(function) ?? true }
        }
        switch source.kind {
        case .sessions: return includeSessions
        case .projects: return !configuration.projects.isEmpty
        case .paths: return !source.paths.isEmpty
        case .command: return true
        case .zoxide: return supports("zoxide", local: tools.zoxide != nil)
        case .find: return supports("find", local: tools.fd != nil)
        case .union: return source.members.contains { sourceIsAvailable($0, includeSessions: includeSessions) }
        }
    }

    private func updateSessions(_ sessions: [RexSession], host: RexHost? = nil) {
        let updated = ReshService.candidates(from: sessions, host: host)
        if let host {
            guard updated != hostSessions[host.id] else { return }
            hostSessions[host.id] = updated
        } else {
            guard updated != sessionSnapshot else { return }
            sessionSnapshot = updated
        }
        if isConfigurationReady { refreshEntries() }
    }

    private func discoverHosts() {
        hostGeneration += 1
        let request = hostGeneration, service = service
        hostsTask?.cancel()
        remoteRequest = UUID()
        for task in remoteTasks.values { task.cancel() }
        remoteTasks = [:]
        hostFunctions = [:]
        hasHostCatalog = false
        refreshEntries()
        hostsTask = Task {
            let worker = Task.detached { try service.hosts() }
            do {
                let catalog = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, hostGeneration == request else { return }
                let updated = catalog.hosts
                let ids = Set(updated.map(\.id))
                let previousHosts = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
                for host in hosts where !ids.contains(host.id) {
                    reportDiagnostic(nil, source: "sources:\(host.id)")
                    reportDiagnostic(nil, source: "attention:\(host.id)")
                }
                hostSessions = hostSessions.filter { ids.contains($0.key) }
                hostSources = hostSources.filter { ids.contains($0.key) }
                hostAttentionRecords = hostAttentionRecords.filter { ids.contains($0.key) }
                pendingHosts.formIntersection(ids)
                for host in updated where previousHosts[host.id] != host {
                    hostSessions[host.id] = nil; hostSources[host.id] = nil; hostAttentionRecords[host.id] = nil
                    pendingHosts.insert(host.id)
                }
                hosts = updated
                self.catalog.updateHosts(updated)
                hasHostCatalog = true
                reportDiagnostic(catalog.warnings.isEmpty ? nil : ReshError(catalog.warnings.joined(separator: "\n")), source: "hosts")
                refreshEntries()
                loadRemoteSources()
            } catch {
                guard !Task.isCancelled, hostGeneration == request else { return }
                reportDiagnostic(error, source: "hosts")
            }
            if hostGeneration == request { hostsTask = nil; updateRemoteLoading() }
        }
        updateRemoteLoading()
    }

    /// Only built-in filesystem providers are mirrored. Local command/project config
    /// is never sent to another machine or executed there implicitly.
    private func remoteSources(_ id: SearchScope) -> [(SearchScope, String)] {
        guard let source = configuration.source(id) else { return [] }
        switch source.kind {
        case .zoxide: return [(id, "zoxide")]
        case .find: return [(id, "find")]
        case .union: return source.members.flatMap(remoteSources)
        default: return []
        }
    }

    private func loadRemoteSources() {
        remoteRequest = UUID()
        let request = remoteRequest, hostRequest = hostGeneration
        for task in remoteTasks.values { task.cancel() }
        remoteTasks = [:]
        guard isConfigurationReady else { updateRemoteLoading(); return }
        var seen = Set<SearchScope>()
        let sources = remoteSources(scope).filter { seen.insert($0.0).inserted }
        for host in hosts {
            let remote = service.remote(host), cached = hostFunctions[host.id]
            remoteTasks[host.id] = Task {
                let worker = Task.detached { () throws -> (Set<String>, [SearchScope: [Candidate]], [String]) in
                    let functions = try cached ?? remote.functions()
                    var snapshots: [SearchScope: [Candidate]] = [:], warnings: [String] = []
                    for (id, function) in sources where functions.contains(function) {
                        try Task.checkCancellation()
                        do {
                            guard functions.contains("resolve") else { throw ReshError("resh integration is missing resolve.") }
                            snapshots[id] = try remote.paths(function: function, host: host)
                        } catch {
                            if error is CancellationError { throw error }
                            warnings.append("\(function): \(error.localizedDescription)")
                        }
                    }
                    return (functions, snapshots, warnings)
                }
                do {
                    let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, remoteRequest == request, hostGeneration == hostRequest else { return }
                    hostFunctions[host.id] = result.0
                    hostSources[host.id] = result.1
                    reportDiagnostic(result.2.isEmpty ? nil : ReshError("\(host.label): " + result.2.joined(separator: "\n")), source: "sources:\(host.id)")
                    refreshEntries()
                } catch {
                    guard !Task.isCancelled, remoteRequest == request, hostGeneration == hostRequest else { return }
                    hostSources[host.id] = nil
                    reportDiagnostic(ReshError("\(host.label): \(error.localizedDescription)"), source: "sources:\(host.id)")
                    refreshEntries()
                }
                if remoteRequest == request { remoteTasks[host.id] = nil; updateRemoteLoading() }
            }
        }
        updateRemoteLoading()
    }

    private func updateRemoteLoading() { isRemoteLoading = hostsTask != nil || !remoteTasks.isEmpty || !pendingHosts.isEmpty }

    private func load(reloadConfiguration: Bool = false, resetScope: Bool = false, refreshSessions: Bool = false,
                      keepingSnapshots: Bool = false) {
        generation += 1
        loadingTask?.cancel()
        if !reloadConfiguration, !keepingSnapshots { sourceSnapshots = [:]; hostSources = [:] }
        remoteRequest = UUID()
        for task in remoteTasks.values { task.cancel() }
        remoteTasks = [:]
        if reloadConfiguration {
            hostGeneration += 1
            hostsTask?.cancel(); hostsTask = nil
            pendingHosts = []
            hasHostCatalog = false
            hostFunctions = [:]
        }
        updateRemoteLoading()
        let request = generation, url = configurationURL, watcher = configurationWatcher
        error = configurationError
        if reloadConfiguration { isConfigurationReady = false }
        if !reloadConfiguration {
            showAvailableEntries()
            loadRemoteSources()
            if configuration.source(scope)?.kind == .sessions {
                isLoading = false; loadingTask = nil
                return
            }
        }
        isLoading = true
        loadingTask = Task {
            defer { if generation == request { isLoading = false; loadingTask = nil } }
            if reloadConfiguration {
                let worker = Task.detached {
                    watcher?.waitUntilReady()
                    return try ConfigurationFile.load(url)
                }
                do {
                    let updated = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard generation == request else { return }
                    if updated != configuration {
                        sourceSnapshots = [:]; hostSources = [:]
                        configuration = updated
                    }
                    configurationError = nil
                    isConfigurationReady = true
                } catch {
                    guard generation == request else { return }
                    let path = (url ?? ConfigurationFile.url()).path
                    if !FileManager.default.fileExists(atPath: path) {
                        configurationError = "Config file not found: \(path)\nCorrect --config in Rex's init.lua and restart the resh service."
                    } else {
                        configurationError = error.localizedDescription + "\nFix this file to reload resh’s configuration."
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
                discoverHosts()
            }
            do {
                if refreshSessions {
                    let provider = snapshotProvider, rexAppPID = rexAppPID
                    let target = rexAppPID == nil ? service.target : RexTarget(server: service.target.server)
                    do {
                        let snapshot = try await Task.detached { try provider.snapshot(target: target, rexAppPID: rexAppPID) }.value
                        guard generation == request else { return }
                        service = ReshService(client: RexClient(tools: tools,
                            target: RexTarget(clientID: snapshot.client, server: target.server)))
                        let recent = try await service.recentSessionIDs()
                        guard generation == request else { return }
                        sessionRanks = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
                        sessionSnapshot = ReshService.candidates(from: snapshot.sessions)
                        reportDiagnostic(nil, source: "connection")
                    } catch {
                        guard generation == request else { return }
                        reportDiagnostic(error, source: "connection")
                    }
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
                if !(error is CancellationError) { reportDiagnostic(error, source: "source:\(scope.rawValue)") }
            }
        }
    }
    func changeScope(_ scope: SearchScope) {
        guard isConfigurationReady, !isOpening, !isConnecting, self.scope != scope else { return }
        guard visibleSources.contains(where: { $0.id == scope }) else { return }
        self.scope = scope; selection = 0; error = configurationError
        load()
    }
    func cycleSource(_ delta: Int) {
        let sources = visibleSources.map(\.id)
        guard let index = sources.firstIndex(of: scope), !sources.isEmpty else { return }
        changeScope(sources[(index + delta + sources.count) % sources.count])
    }
    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }
    func openSelection() {
        guard isConfigurationReady, !isOpening, !isConnecting, let candidate = selected else { return }
        isConnecting = true; error = nil
        let request = generation, service = service
        Task {
            do {
                try await service.connect(candidate)
                guard generation == request else { return }
                catalog.refreshHistory()
                onDismiss?(true)
            } catch {
                guard generation == request else { return }
                reportDiagnostic(error, source: "open:\(candidate.id)")
                self.error = (error as? ReshError)?.userMessage
                if self.error == nil {
                    if candidate.sessionID != nil {
                        do {
                            let sessions = try await Task.detached { try service.sessions(host: candidate.host) }.value
                            guard generation == request else { return }
                            updateSessions(sessions, host: candidate.host)
                        } catch { reportDiagnostic(error, source: "sessions:\(candidate.host?.id ?? "local")") }
                    } else { load() }
                }
                guard generation == request else { return }
                isConnecting = false
            }
        }
    }
    func deleteSelection() {
        guard isConfigurationReady, !isOpening, !isConnecting, let selected, let sessionID = selected.sessionID else { return }
        let alert = NSAlert()
        alert.messageText = "Close ‘\(selected.title)’" + (showsHosts ? " on \(selected.hostLabel)?" : "?")
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
        let request = generation, service = service
        Task {
            do {
                try await service.delete(sessionID: sessionID, host: selected.host)
                guard generation == request else { return }
                if let host = selected.host { hostSessions[host.id]?.removeAll { $0.id == selected.id } }
                else { sessionSnapshot.removeAll { $0.id == selected.id } }
                refreshEntries()
            } catch {
                guard generation == request else { return }
                reportDiagnostic(error, source: "close:\(selected.id)")
            }
            if generation == request { isConnecting = false }
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
        let message = error?.localizedDescription
        guard diagnostics[source] != message else { return }
        diagnostics[source] = message
        if let message { DebugLog.shared.record(message, source: source) }
    }

    func receive(_ result: Result<RexEventUpdate, Error>, host: RexHost? = nil) {
        let key = host.map { "attention:\($0.id)" } ?? "attention"
        switch result {
        case .success(.clients): break
        case .success(.reconnecting):
            if let host { pendingHosts.insert(host.id); updateRemoteLoading() }
        case .success(.hostsChanged):
            if host == nil { discoverHosts() }
        case .success(.capabilitiesChanged):
            if let host { hostFunctions[host.id] = nil; refreshEntries(); loadRemoteSources() }
            else { discoverHosts() }
        case let .success(.records(records)):
            reportDiagnostic(nil, source: key)
            if let host { hostAttentionRecords[host.id] = records; refreshAttention() }
            else { updateAttention(records) }
        case let .success(.sessions(sessions)):
            if let host { pendingHosts.remove(host.id); updateRemoteLoading() }
            reportDiagnostic(nil, source: key)
            updateSessions(sessions, host: host)
            if let host, hostFunctions[host.id] == nil, remoteTasks[host.id] == nil { loadRemoteSources() }
        case let .failure(error):
            if let host { pendingHosts.remove(host.id); updateRemoteLoading() }
            reportDiagnostic(error, source: key)
        }
    }

    func updateAttention(_ records: [RexAttentionRecord]) {
        reportDiagnostic(nil, source: "attention")
        attentionRecords = records
        refreshAttention()
    }

    func refreshAttention() {
        attentionTask?.cancel()
        let records = attentionRecords, remoteRecords = hostAttentionRecords, hosts = hosts
        let request = generation, preferences = readPreferences
        guard !records.isEmpty || remoteRecords.values.contains(where: { !$0.isEmpty }) else {
            attentionSessionIDs = []; attentionTask = nil
            reportDiagnostic(nil, source: "receipts")
            return
        }
        attentionTask = Task {
            do {
                let unseen = try await Task.detached {
                    let ledger = preferences()
                    var unseen = try RexAttention.unseenSessionIDs(in: records, preferences: ledger)
                    for host in hosts {
                        let ids = try RexAttention.unseenSessionIDs(in: remoteRecords[host.id] ?? [], preferences: ledger)
                        unseen.formUnion(ids.map { Candidate.identity($0, host: host) })
                    }
                    return unseen
                }.value
                guard !Task.isCancelled, generation == request else { return }
                if attentionSessionIDs != unseen { attentionSessionIDs = unseen }
                reportDiagnostic(nil, source: "receipts")
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                attentionSessionIDs = []
                reportDiagnostic(error, source: "receipts")
            }
        }
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
