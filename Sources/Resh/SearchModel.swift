import AppKit
import ReshCore
import RexFocusTracking
import Combine

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { updateResults(); selectFirstResult() } }
    @Published private(set) var scope: SearchScope = .sessions
    @Published var selection = 0
    @Published var isLoading = true
    @Published private(set) var isRemoteLoading = false
    @Published private(set) var hosts: [RexHost] = []
    @Published var isConnecting = false
    @Published private(set) var isOpening = false
    @Published var error: String?
    @Published var theme: RexTheme
    @Published private(set) var results: [Candidate] = []
    @Published private(set) var attentionSessionIDs = Set<String>()
    @Published private(set) var attentionAgentIDs = Set<String>()
    @Published private(set) var workingAgentIDs = Set<String>()
    @Published private(set) var pinnedSessionIDs: [String] = []
    @Published private(set) var currentCandidateID: String?
    private var currentSessionID: String?
    private(set) var animatesResultChanges = false
    let configuration: ReshConfiguration
    @Published private(set) var keymap = Keymap.defaults
    @Published var keyModes = ["resh"]
    private(set) var isKeymapReady = false
    @Published private(set) var visibleSources = ReshConfiguration.defaults.visibleSources
    let configurationURL: URL
    let configurationError: String?
    var isConfigurationReady: Bool { configurationError == nil }
    private var search = FuzzyMatcher([])
    private var keyboardLayouts = KeyboardLayouts([])
    private var sessionSnapshot: [Candidate] = []
    private var agentSnapshot: [Candidate] = []
    private var sessionRanks: [String: Int] = [:]
    private var sourceSnapshots: [SearchScope: [Candidate]] = [:]
    private var hostSessions: [String: [Candidate]] = [:]
    private var hostSources: [String: [SearchScope: [Candidate]]] = [:]
    private var hostFunctions: [String: Set<String>] = [:]
    private var hasHostCatalog = false
    private var hasAuthoritativeHostCatalog = false
    private var verifiedSessionHosts = Set<String>()
    private var pendingHosts = Set<String>()
    private var remoteTasks: [String: Task<Void, Never>] = [:]
    private(set) var hostsTask: Task<Void, Never>?
    private var hostGeneration = 0
    private var remoteRequest = UUID()
    private var rexAppPID: Int32?
    let catalog: SessionStore
    private(set) var keymapError: String?
    private let focusTracker: RexFocusTracker?
    private var observedFocus: String?
    private var stateReconciliationTask: Task<Void, Never>?
    private var pendingCreation: (name: String, sessionID: String, host: RexHost?)?
    private var isBackgroundActive = false
    private var subscriptions = Set<AnyCancellable>()
    private let snapshotProvider: any RexSnapshotProviding
    private let readPreferences: @Sendable () -> [String: Any]
    private let readFocusedSession: @MainActor (Int32?) -> String?
    private let readKeyboardLayouts: @MainActor () -> KeyboardLayouts
    private let readTheme: @Sendable (String, Bool) throws -> RexTheme
    private var diagnostics: [String: String] = [:]
    private(set) var service: ReshService
    let tools: Tools
    var loadingTask: Task<Void, Never>?
    private(set) var actionTask: Task<Void, Never>?
    private(set) var attentionTask: Task<Void, Never>?
    private var themeTask: Task<Void, Never>?
    private var themeTaskID: UUID?
    private var attentionRecords: [RexAttentionRecord] = []
    private var hostAttentionRecords: [String: [RexAttentionRecord]] = [:]
    var onDismiss: ((Bool) -> Void)?
    var onRetryOpening: (() -> Void)?
    private var generation = 0

    init(service: ReshService, tools: Tools, sessions: [RexSession] = [], recentSessionIDs: [String] = [], configurationURL: URL? = nil,
         snapshotProvider: (any RexSnapshotProviding)? = nil,
         readTheme: @escaping @Sendable (String, Bool) throws -> RexTheme = { try RexTheme.read(rexApp: $0, systemIsDark: $1) },
         readPreferences: @escaping @Sendable () -> [String: Any] = { RexTheme.preferences(keys: ["Workspace.programActivitySeen"]) },
         readFocusedSession: (@MainActor (Int32?) -> String?)? = nil,
         readKeyboardLayouts: @escaping @MainActor () -> KeyboardLayouts = { .enabled() }) {
        self.service = service; self.tools = tools
        self.catalog = SessionStore(tools: tools, service: service)
        self.configurationURL = (configurationURL ?? ConfigurationFile.url()).standardizedFileURL
        do {
            self.configuration = try ConfigurationFile.load(configurationURL)
            self.configurationError = nil
        } catch {
            self.configuration = .defaults
            self.configurationError = error.localizedDescription + "\nFix the configuration and run resh service restart."
        }
        self.snapshotProvider = snapshotProvider ?? RexDataConnection(tools: tools)
        self.readPreferences = readPreferences
        let tracker = readFocusedSession == nil ? RexFocusTracker() : nil
        self.focusTracker = tracker
        self.readFocusedSession = readFocusedSession ?? { tracker?.selectedSession(in: $0) }
        self.readTheme = readTheme
        self.readKeyboardLayouts = readKeyboardLayouts
        if configuration.keyboardLayoutSearch { keyboardLayouts = readKeyboardLayouts() }
        do { self.theme = try readTheme(tools.rexApp, Self.systemIsDark) }
        catch {
            self.theme = .fallback(systemIsDark: Self.systemIsDark)
            DebugLog.shared.record(error, source: "theme")
        }
        sessionSnapshot = ReshService.candidates(from: sessions)
        pinnedSessionIDs = service.pinnedSessionIDs()
        sessionRanks = Dictionary(recentSessionIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        scope = configuration.initialSource
        error = configurationError
        showAvailableEntries()
        isLoading = false
        catalog.updates.sink { [weak self] result, host in
            self?.receive(result, host: host)
        }.store(in: &subscriptions)
        catalog.$recentSessionIDs.dropFirst().sink { [weak self] history in
            self?.updateRecentSessions(history)
        }.store(in: &subscriptions)
        catalog.$stateError.sink { [weak self] message in
            self?.reportDiagnostic(message.map { ReshError($0) }, source: "state")
        }.store(in: &subscriptions)
        tracker?.onChange = { [weak self] in self?.refreshFocus() }
        tracker?.onDiagnostic = { [weak self] in self?.reportDiagnostic($0, source: "focus") }
    }
    static var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }
    var selected: Candidate? { results.indices.contains(selection) ? results[selection] : nil }
    var numberedRows: [Int] { Array(results.indices.filter { results[$0].id != currentCandidateID }.prefix(9)) }
    var sessionCandidates: [Candidate] { sessionSnapshot + hosts.flatMap { hostSessions[$0.id] ?? [] } }
    private var allSessions: [Candidate] {
        sessionCandidates.enumerated().sorted {
            let left = sessionRanks[$0.element.sessionID ?? $0.element.id] ?? Int.max
            let right = sessionRanks[$1.element.sessionID ?? $1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    var sessionCount: Int { allSessions.count }
    var showsHosts: Bool { !hosts.isEmpty }
    private var currentSession: Candidate? {
        guard let currentSessionID else { return nil }
        let matches = sessionCandidates.filter { $0.sessionID == currentSessionID }
        return matches.count == 1 ? matches.first : nil
    }
    var newSessionHost: RexHost? { currentSession?.host }
    private var isNewSessionHostResolved: Bool { currentSessionID == nil || currentSession != nil }
    var canCreateSession: Bool {
        isConfigurationReady && !isOpening && !isConnecting && onRetryOpening == nil && isNewSessionHostResolved
    }
    var panelHeight: CGFloat { PanelLayout.height(resultCount: results.count, hasError: error != nil) }
    var canRetry: Bool { configurationError == nil }
    var offersNewSession: Bool {
        isConfigurationReady && !isOpening && !isLoading && !isRemoteLoading && onRetryOpening == nil
            && isNewSessionHostResolved && results.isEmpty && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var emptyMessage: String {
        if isOpening { return "Loading sessions…" }
        if isLoading || isRemoteLoading { return "Loading…" }
        if !isNewSessionHostResolved { return "Active session host unavailable" }
        if !query.isEmpty { return "No matches" }
        if configuration.source(scope)?.kind == .agents { return "No agents" }
        return configuration.source(scope)?.kind == .sessions ? "No sessions" : "No folders or projects"
    }

    func loadInitial() {
        guard isConfigurationReady else { return }
        scope = configuration.initialSource
        discoverHosts()
        load()
    }

    func startBackground() {
        catalog.start()
        guard !isBackgroundActive else { return }
        isBackgroundActive = true
        watchFocus()
        loadInitial()
    }

    @discardableResult
    func stopBackground() -> [RexEventConnection] {
        isBackgroundActive = false
        focusTracker?.stop()
        stateReconciliationTask?.cancel(); stateReconciliationTask = nil
        generation += 1
        hostGeneration += 1
        hostsTask?.cancel(); hostsTask = nil
        remoteRequest = UUID()
        for task in remoteTasks.values { task.cancel() }
        remoteTasks = [:]
        loadingTask?.cancel(); loadingTask = nil
        actionTask?.cancel(); actionTask = nil
        attentionTask?.cancel(); attentionTask = nil
        themeTask?.cancel(); themeTask = nil; themeTaskID = nil
        isLoading = false
        return catalog.stop()
    }

    func configure(target: RexTarget) {
        guard service.target.server != target.server else { return }
        clear()
        service = service.at(target)
        catalog.configure(target: target)
        startBackground()
    }

    private func updateRecentSessions(_ recent: [String]) {
        let ranks = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        guard ranks != sessionRanks else { return }
        sessionRanks = ranks
        refreshEntries()
    }

    func beginOpening() {
        isOpening = true
        isLoading = true
        error = configurationError ?? keymapError
    }

    func prepare(service: ReshService, sessions: [RexSession], recentSessionIDs: [String] = [], rexAppPID: Int32? = nil,
                 currentSessionID: String? = nil) {
        if configuration.keyboardLayoutSearch { keyboardLayouts = readKeyboardLayouts() }
        if !isOpening { query = ""; selection = 0 }
        self.service = service
        self.rexAppPID = rexAppPID
        self.currentSessionID = currentSessionID
        sessionSnapshot = ReshService.candidates(from: sessions)
        pinnedSessionIDs = service.pinnedSessionIDs()
        verifiedSessionHosts.insert(service.target.server)
        sessionRanks = Dictionary(recentSessionIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        scope = configuration.initialSource
        showAvailableEntries()
        selectFirstResult()
        isOpening = false
        isLoading = loadingTask != nil
        onRetryOpening = nil
        if isConfigurationReady, configuration.source(scope)?.kind != .sessions { load(keepingSnapshots: true) }
        watchFocus(updateCurrent: currentSessionID == nil)
    }

    func failOpening(_ error: Error, retry: @escaping () -> Void) {
        isOpening = false; isLoading = false
        self.error = configurationError ?? keymapError ?? error.localizedDescription
        onRetryOpening = retry
    }

    func endPresentation() {
        pendingCreation = nil
        query = ""; scope = configuration.initialSource; selection = 0
        isOpening = false; isConnecting = false
        isLoading = loadingTask != nil
        error = configurationError ?? keymapError
        onRetryOpening = nil
        showAvailableEntries()
    }

    func clear() {
        stopBackground()
        hosts = []; hostSessions = [:]; hostSources = [:]; hostFunctions = [:]
        hasHostCatalog = false; hasAuthoritativeHostCatalog = false; verifiedSessionHosts = []
        visibleSources = configuration.visibleSources
        pendingHosts = []
        hostAttentionRecords = [:]; isRemoteLoading = false
        attentionRecords = []; attentionSessionIDs = []; attentionAgentIDs = []; workingAgentIDs = []; agentSnapshot = []
        sessionSnapshot = []; sessionRanks = [:]; search = FuzzyMatcher([])
        pinnedSessionIDs = []; currentSessionID = nil; currentCandidateID = nil
        observedFocus = nil; pendingCreation = nil
        sourceSnapshots = [:]
        rexAppPID = nil
        diagnostics = [:]
        keymapError = nil
        keymap = .defaults
        isKeymapReady = false
        isOpening = false
        onRetryOpening = nil
        query = ""; scope = configuration.initialSource; selection = 0
        isLoading = false; isConnecting = false; error = configurationError
        updateResults()
    }

    func retry() {
        if let onRetryOpening { onRetryOpening(); return }
        guard isConfigurationReady else { return }
        discoverHosts()
        load(refreshSessions: true)
    }

    private func updateResults() {
        // A session ID must identify exactly one known host. Never infer focus
        // from attachment order, a session label, or resh's MRU history.
        let currentID = currentSession?.id
        if currentCandidateID != currentID { currentCandidateID = currentID }
        let floatingIDs = (configuration.floatUnreadSessions ? attentionSessionIDs : [])
            .union(configuration.floatUnreadAgents ? attentionAgentIDs : [])
        let alternatives = keyboardLayouts.alternatives(for: query)
        let updated: [Candidate]
        if configuration.source(scope)?.kind == .agents {
            let matching = Set(search.filter(query: query, alternatives: alternatives, limit: search.entries.count).map(\.id))
            let entries = search.entries.filter { matching.contains($0.id) }
            updated = Array((entries.filter { floatingIDs.contains($0.id) }
                + entries.filter { !floatingIDs.contains($0.id) }).prefix(100))
        } else if pinnedSessionIDs.isEmpty, currentID == nil, floatingIDs.isEmpty {
            updated = search.filter(query: query, alternatives: alternatives)
        } else {
            let matching = search.filter(query: query, alternatives: alternatives, limit: search.entries.count)
            var byID = Dictionary(matching.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var ordered = pinnedSessionIDs.compactMap { sessionID -> Candidate? in
                guard let entry = matching.first(where: { $0.kind == .session && $0.sessionID == sessionID }) else { return nil }
                return byID.removeValue(forKey: entry.id)
            }
            if let currentID, let entry = byID.removeValue(forKey: currentID) { ordered.append(entry) }
            for entry in matching where floatingIDs.contains(entry.id) {
                if let entry = byID.removeValue(forKey: entry.id) { ordered.append(entry) }
            }
            ordered += matching.filter { byID[$0.id] != nil }
            updated = Array(ordered.prefix(100))
        }
        if updated != results { results = updated }
        if !results.indices.contains(selection) { selection = 0 }
    }

    private func selectFirstResult() {
        selection = results.firstIndex { $0.id != currentCandidateID } ?? 0
    }

    func togglePin() {
        guard isConfigurationReady, !isOpening, !isConnecting, let selected, selected.kind == .session,
              let sessionID = selected.sessionID else { return }
        animatesResultChanges = true
        defer { animatesResultChanges = false }
        pinnedSessionIDs = service.togglePin(sessionID: sessionID)
        catalog.refreshState()
        updateResults()
        selection = results.firstIndex { $0.id == selected.id } ?? 0
    }

    func openResult(_ number: Int) {
        let rows = numberedRows, index = number - 1
        guard isConfigurationReady, !isOpening, !isConnecting, rows.indices.contains(index) else { return }
        selection = rows[index]
        openSelection()
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
        let agents = allSessions.flatMap { session in
            RexAgent.panes(in: session.host.map { hostAttentionRecords[$0.id] ?? [] } ?? attentionRecords, session: session)
        }
        agentSnapshot = agents.map(\.candidate)
        let working = Set(agents.filter(\.isWorking).map(\.candidate.id))
        if workingAgentIDs != working { workingAgentIDs = working }
        var visible = configuration.visibleSources.filter {
            $0.id == configuration.initialSource || sourceIsAvailable($0.id, includeSessions: $0.id != .all || $0.kind != .union)
        }
        let needsFallback = !visible.contains { $0.id == scope }
        if needsFallback, !visible.contains(where: { $0.id == .sessions }), let sessions = configuration.source(.sessions) {
            visible.insert(sessions, at: 0)
        }
        if visibleSources != visible { visibleSources = visible }
        if needsFallback, scope != .sessions, isConfigurationReady {
            scope = .sessions
            if isConnecting { refreshEntries() }
            else { load() }
            return
        }
        let selectedID = selected?.id, previousSelection = selection
        var snapshots = sourceSnapshots
        for host in hosts {
            for (source, entries) in hostSources[host.id] ?? [:] { snapshots[source, default: []] += entries }
        }
        let entries = SourceLoader(tools: tools).availableEntries(scope,
            configuration: configuration, sessions: allSessions, snapshots: snapshots, agents: agentSnapshot)
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
        case .agents: return !agentSnapshot.isEmpty
        case .projects: return !configuration.projects.isEmpty
        case .paths: return !source.paths.isEmpty
        case .command: return true
        case .zoxide: return supports("zoxide", local: tools.zoxide != nil)
        case .find: return supports("find", local: tools.fd != nil)
        case .union: return source.members.contains { sourceIsAvailable($0, includeSessions: includeSessions) }
        }
    }

    private func updateSessions(_ sessions: [RexSession], host: RexHost? = nil) {
        verifiedSessionHosts.insert(host?.id ?? service.target.server)
        let updated = ReshService.candidates(from: sessions, host: host)
        let previous = host.map { hostSessions[$0.id] ?? [] } ?? sessionSnapshot
        let removed = Set(previous.map(\.id)).subtracting(updated.map(\.id))
        for candidate in previous where removed.contains(candidate.id) {
            if let id = candidate.sessionID { removeSession(id, host: host) }
        }
        if let host {
            guard updated != hostSessions[host.id] else { reconcileState(); return }
            hostSessions[host.id] = updated
        } else {
            guard updated != sessionSnapshot else { reconcileState(); return }
            sessionSnapshot = updated
        }
        if isConfigurationReady { refreshEntries() }
        refreshFocus()
        reconcileState()
    }

    private func watchFocus(updateCurrent: Bool = true) {
        focusTracker?.start()
        refreshFocus(updateCurrent: updateCurrent)
    }

    func focusedSessionID(rexAppPID: Int32?) -> String? { readFocusedSession(rexAppPID) }

    func refreshFocus(updateCurrent: Bool = true) {
        // Only actual focus changes are visits. Catalog updates and background
        // session creation must not reorder history.
        var clients = catalog.clients
        if let rexAppPID, let client = service.target.clientID, !clients.contains(where: { $0.client == client }) {
            clients.append(RexAppClient(client: client, rexAppPID: rexAppPID))
        }
        for client in clients {
            guard let sessionID = readFocusedSession(client.rexAppPID) else { continue }
            if updateCurrent, service.target.clientID == client.client, currentSessionID != sessionID {
                currentSessionID = sessionID
                refreshEntries()
            }
            let matches = sessionCandidates.filter { $0.sessionID == sessionID }
            guard matches.count == 1, let candidate = matches.first else { continue }
            let previous = observedFocus
            guard previous != candidate.id else { continue }
            observedFocus = candidate.id
            DebugLog.shared.record("\(client.client): \(candidate.id)", source: "focus")
            let service = service, observedAt = ContinuousClock.now
            Task {
                await service.recordVisit(sessionID: sessionID, observedAt: observedAt, initial: previous == nil)
                guard self.service.target.server == service.target.server else { return }
                await catalog.refreshState().value
            }
        }
    }

    private func reconcileState() {
        guard hasAuthoritativeHostCatalog, verifiedSessionHosts.contains(service.target.server),
              hosts.allSatisfy({ verifiedSessionHosts.contains($0.id) }) else { return }
        let service = service, ids = Set(sessionCandidates.compactMap(\.sessionID))
        stateReconciliationTask?.cancel()
        stateReconciliationTask = Task {
            guard !Task.isCancelled else { return }
            await service.reconcileState(sessionIDs: ids)
            guard !Task.isCancelled else { return }
            let pins = service.pinnedSessionIDs()
            if pins != pinnedSessionIDs {
                pinnedSessionIDs = pins
                refreshEntries()
            }
            await catalog.refreshState().value
        }
    }

    private func removeSession(_ sessionID: String, host: RexHost?) {
        let id = Candidate.identity(sessionID, host: host)
        if let pendingCreation, Candidate.identity(pendingCreation.sessionID, host: pendingCreation.host) == id {
            self.pendingCreation = nil
        }
        if let host { hostSessions[host.id]?.removeAll { $0.id == id } }
        else { sessionSnapshot.removeAll { $0.id == id } }
        service.forgetSession(sessionID: sessionID)
        pinnedSessionIDs = service.pinnedSessionIDs()
        refreshEntries()
        refreshFocus()
        catalog.refreshState()
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
        hasAuthoritativeHostCatalog = false
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
                    verifiedSessionHosts.remove(host.id)
                    hostSessions[host.id] = nil; hostSources[host.id] = nil; hostAttentionRecords[host.id] = nil
                    pendingHosts.insert(host.id)
                }
                hosts = updated
                self.catalog.updateHosts(updated)
                hasHostCatalog = true
                hasAuthoritativeHostCatalog = catalog.warnings.isEmpty
                reportDiagnostic(catalog.warnings.isEmpty ? nil : ReshError(catalog.warnings.joined(separator: "\n")), source: "hosts")
                refreshEntries()
                loadRemoteSources()
                reconcileState()
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

    private func load(refreshSessions: Bool = false, keepingSnapshots: Bool = false) {
        guard isConfigurationReady else { return }
        generation += 1
        loadingTask?.cancel()
        if !keepingSnapshots { sourceSnapshots = [:]; hostSources = [:] }
        let request = generation
        error = keymapError
        showAvailableEntries()
        loadRemoteSources()
        if !refreshSessions, let kind = configuration.source(scope)?.kind, kind == .sessions || kind == .agents {
            isLoading = false; loadingTask = nil
            return
        }
        isLoading = true
        loadingTask = Task {
            defer { if generation == request { isLoading = false; loadingTask = nil } }
            do {
                if refreshSessions {
                    let provider = snapshotProvider, rexAppPID = rexAppPID
                    let target = rexAppPID == nil ? service.target : RexTarget(server: service.target.server)
                    do {
                        let snapshot = try await Task.detached { try provider.snapshot(target: target, rexAppPID: rexAppPID) }.value
                        guard generation == request else { return }
                        service = service.at(RexTarget(clientID: snapshot.client, server: target.server))
                        await catalog.refreshState().value
                        guard generation == request else { return }
                        sessionRanks = Dictionary(catalog.recentSessionIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
                        sessionSnapshot = ReshService.candidates(from: snapshot.sessions)
                        reportDiagnostic(nil, source: "connection")
                    } catch {
                        guard generation == request else { return }
                        reportDiagnostic(error, source: "connection")
                    }
                    showAvailableEntries()
                }
                let loader = SourceLoader(tools: tools), sessions = sessionSnapshot, agents = agentSnapshot
                let source = scope, configuration = configuration
                let worker = Task.detached {
                    let result = try loader.load(source, configuration: configuration, sessions: sessions, agents: agents)
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
        self.scope = scope; selection = 0; error = configurationError ?? keymapError
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
    @discardableResult
    func openSelection() -> Task<Void, Never>? {
        if offersNewSession { return createSession() }
        guard isConfigurationReady, !isOpening, !isConnecting, let candidate = selected else { return nil }
        isConnecting = true; error = nil
        let request = generation, service = service, current = currentSession
        let currentID = currentSessionID, candidates = sessionCandidates
        return Task {
            do {
                var source = current
                if source == nil, let currentID {
                    source = try await Task.detached { try service.session(currentID, candidates: candidates) }.value
                    guard generation == request else { return }
                }
                try await service.connect(candidate, from: source)
                guard generation == request else { return }
                catalog.refreshState()
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
    @discardableResult
    func createSession() -> Task<Void, Never>? {
        guard canCreateSession else { return nil }
        isConnecting = true; error = nil
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = newSessionHost
        let request = generation, service = service, current = currentSession
        return Task {
            do {
                let sessionID: String
                if let pendingCreation, pendingCreation.name == name, pendingCreation.host?.id == host?.id {
                    sessionID = pendingCreation.sessionID
                } else {
                    sessionID = try await service.createSession(name: name, host: host)
                    guard generation == request else { return }
                    // A failed switch must not create another session on retry.
                    pendingCreation = (name, sessionID, host)
                }
                try await service.connect(Candidate(id: Candidate.identity(sessionID, host: host), kind: .session,
                    title: name, sessionID: sessionID, host: host), from: current)
                guard generation == request else { return }
                catalog.refreshState()
                pendingCreation = nil
                onDismiss?(true)
            } catch {
                guard generation == request else { return }
                reportDiagnostic(error, source: "create")
                self.error = (error as? ReshError)?.userMessage
                isConnecting = false
            }
        }
    }
    func performRexAction(_ invocation: KeyInvocation) {
        guard isConfigurationReady, !isOpening else { return }
        let previous = actionTask, request = generation, service = service, sessionID = currentSessionID
        actionTask = Task {
            await previous?.value
            guard generation == request, !Task.isCancelled else { return }
            let source = "action:\(invocation.action)"
            let message = "Couldn’t run Rex action ‘\(invocation.action)’."
            do {
                try await service.perform(invocation, sessionID: sessionID)
                guard generation == request else { return }
                reportDiagnostic(nil, source: source)
                if error == message { error = configurationError ?? keymapError }
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                reportDiagnostic(error, source: source)
                self.error = configurationError ?? keymapError ?? message
            }
        }
    }

    func deleteSelection() {
        guard isConfigurationReady, !isOpening, !isConnecting, let selected, selected.kind == .session,
              let sessionID = selected.sessionID else { return }
        isConnecting = true
        let request = generation, service = service
        Task {
            do {
                try await service.delete(sessionID: sessionID, host: selected.host)
                guard generation == request else { return }
                removeSession(sessionID, host: selected.host)
            } catch {
                guard generation == request else { return }
                reportDiagnostic(error, source: "close:\(selected.id)")
            }
            if generation == request { isConnecting = false }
        }
    }
    func openPreviousSession() {
        guard isConfigurationReady, !isOpening, !isConnecting else { return }
        isConnecting = true
        let service = service, current = currentSession, request = generation
        let currentID = currentSessionID, candidates = sessionCandidates
        Task {
            defer { if generation == request { isConnecting = false } }
            do {
                var source = current
                if source == nil, let currentID {
                    source = try await Task.detached { try service.session(currentID, candidates: candidates) }.value
                    guard generation == request else { return }
                }
                if try await service.connectLast(from: source) != nil {
                    guard generation == request else { return }
                    catalog.refreshState()
                    onDismiss?(true)
                }
            } catch { reportDiagnostic(error, source: "last") }
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
        case let .success(.keymap(map)):
            guard host == nil else { return }
            keymap = map
            isKeymapReady = true
            validateKeymap()
        case let .success(.keymapError(message)):
            guard host == nil else { return }
            keymapError = message
            reportDiagnostic(ReshError(message), source: "keymap")
            error = configurationError ?? keymapError
        case .success(.clients): watchFocus()
        case let .success(.destroyed(sessionID)):
            removeSession(sessionID, host: host)
        case .success(.reconnecting):
            verifiedSessionHosts.remove(host?.id ?? service.target.server)
            if let host { pendingHosts.insert(host.id); updateRemoteLoading() }
        case .success(.hostsChanged):
            if host == nil { discoverHosts() }
        case .success(.capabilitiesChanged):
            if let host { hostFunctions[host.id] = nil; refreshEntries(); loadRemoteSources() }
            else { discoverHosts() }
        case let .success(.records(records)):
            reportDiagnostic(nil, source: key)
            if let host { hostAttentionRecords[host.id] = records; refreshEntries(); refreshAttention() }
            else { updateAttention(records) }
        case let .success(.sessions(sessions)):
            if let host { pendingHosts.remove(host.id); updateRemoteLoading() }
            reportDiagnostic(nil, source: key)
            updateSessions(sessions, host: host)
            if let host, hostFunctions[host.id] == nil, remoteTasks[host.id] == nil { loadRemoteSources() }
        case let .failure(error):
            verifiedSessionHosts.remove(host?.id ?? service.target.server)
            if let host { pendingHosts.remove(host.id); updateRemoteLoading() }
            reportDiagnostic(error, source: key)
        }
    }

    private func validateKeymap() {
        let previousError = keymapError
        let diagnostics = keymap.diagnostics(sources: Set(configuration.sources.map(\.id)))
        keymapError = diagnostics.isEmpty ? nil : diagnostics.joined(separator: "\n")
        if error == nil || error == previousError || keymapError != nil { error = configurationError ?? keymapError }
        reportDiagnostic(keymapError.map { ReshError($0) }, source: "keymap")
    }

    func updateAttention(_ records: [RexAttentionRecord]) {
        reportDiagnostic(nil, source: "attention")
        attentionRecords = records
        refreshEntries()
        refreshAttention()
    }

    func refreshAttention() {
        attentionTask?.cancel()
        let records = attentionRecords, remoteRecords = hostAttentionRecords, hosts = hosts
        let request = generation, preferences = readPreferences
        guard !records.isEmpty || remoteRecords.values.contains(where: { !$0.isEmpty }) else {
            applyAttention(sessionIDs: [], agentIDs: []); attentionTask = nil
            reportDiagnostic(nil, source: "receipts")
            return
        }
        attentionTask = Task {
            do {
                let unseen = try await Task.detached {
                    let ledger = preferences()
                    let local = try RexAttention.unseenRecords(in: records, preferences: ledger)
                    var sessions = Set(local.map(\.sessionID))
                    var agents = Set(local.map { RexAgent.identity(sessionID: $0.sessionID, blockID: $0.blockID) })
                    for host in hosts {
                        let unseen = try RexAttention.unseenRecords(in: remoteRecords[host.id] ?? [], preferences: ledger)
                        sessions.formUnion(unseen.map { Candidate.identity($0.sessionID, host: host) })
                        agents.formUnion(unseen.map { RexAgent.identity(sessionID: $0.sessionID, blockID: $0.blockID, host: host) })
                    }
                    return (sessions, agents)
                }.value
                guard !Task.isCancelled, generation == request else { return }
                applyAttention(sessionIDs: unseen.0, agentIDs: unseen.1)
                reportDiagnostic(nil, source: "receipts")
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                applyAttention(sessionIDs: [], agentIDs: [])
                reportDiagnostic(error, source: "receipts")
            }
        }
    }

    private func applyAttention(sessionIDs: Set<String>, agentIDs: Set<String>) {
        guard attentionSessionIDs != sessionIDs || attentionAgentIDs != agentIDs else { return }
        let selectedID = selected?.id, previousSelection = selection
        animatesResultChanges = true
        defer { animatesResultChanges = false }
        if attentionSessionIDs != sessionIDs { attentionSessionIDs = sessionIDs }
        if attentionAgentIDs != agentIDs { attentionAgentIDs = agentIDs }
        updateResults()
        selection = selectedID.flatMap { id in results.firstIndex { $0.id == id } }
            ?? min(previousSelection, max(0, results.count - 1))
    }
}

extension RGBA {
    var nsColor: NSColor {
        switch colorSpace {
        case .sRGB: NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        case .displayP3: NSColor(displayP3Red: red, green: green, blue: blue, alpha: alpha)
        }
    }
}
