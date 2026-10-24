import Combine
import Foundation
import ReshCore

/// Application-owned catalog. Panel visibility never starts, stops or clears it.
@MainActor
final class SessionStore {
    let updates = PassthroughSubject<(Result<RexEventUpdate, Error>, RexHost?), Never>()
    @Published private(set) var recentSessionIDs: [String: [String]] = [:]
    private(set) var sessions: [RexSession]?
    private(set) var clients: [RexAppClient] = []
    private(set) var isConnected = false
    private let tools: Tools
    private let connection: RexEventConnection
    private var service: ReshService
    private var remoteConnections: [String: (RexHost, RexEventConnection)] = [:]
    private var hosts: [RexHost] = []
    private var target: RexTarget
    private var running = false
    private var generation = 0
    private var historyTask: Task<Void, Never>?

    var processID: pid_t? { connection.processID }

    init(tools: Tools, service: ReshService) {
        self.tools = tools; self.service = service
        self.target = RexTarget(server: service.target.server)
        connection = RexEventConnection(tools: tools, kind: .catalog)
    }

    func start() {
        guard !running else { updateHosts(hosts); return }
        for (_, connection) in remoteConnections.values { connection.stop() }
        remoteConnections = [:]
        running = true
        generation += 1
        let request = generation
        refreshHistory()
        connection.start(target: target) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, generation == request, running else { return }
                switch result {
                case let .success(.sessions(sessions)):
                    self.sessions = sessions; isConnected = true
                case let .success(.destroyed(sessionID)):
                    sessions?.removeAll { $0.sessionID == sessionID }
                case let .success(.clients(clients)): self.clients = clients
                case .success(.reconnecting): isConnected = false
                case .failure: isConnected = false; running = false
                default: break
                }
                updates.send((result, nil))
            }
        }
        updateHosts(hosts)
    }

    func configure(target: RexTarget) {
        guard target.server != self.target.server else { return }
        stop()
        self.target = RexTarget(server: target.server)
        service = service.at(self.target)
        sessions = nil; clients = []; hosts = []; recentSessionIDs = [:]
        start()
    }

    func snapshot(clientID: String?, rexAppPID: Int32?) -> RexSnapshot? {
        guard isConnected, let sessions else { return nil }
        let selected = clients.first {
            if let clientID { return $0.client == clientID }
            return rexAppPID != nil && $0.rexAppPID == rexAppPID
        }
        guard let selected else { return nil }
        return RexSnapshot(client: selected.client, rexAppPID: selected.rexAppPID, sessions: sessions)
    }

    func updateHosts(_ hosts: [RexHost]) {
        self.hosts = hosts
        let ids = Set(hosts.map(\.id))
        for id in Array(remoteConnections.keys) where !ids.contains(id) {
            remoteConnections.removeValue(forKey: id)?.1.stop()
        }
        guard running else { return }
        for host in hosts {
            if remoteConnections[host.id]?.0 == host { continue }
            remoteConnections.removeValue(forKey: host.id)?.1.stop()
            let connection = RexEventConnection(tools: tools, kind: .catalog), request = generation
            remoteConnections[host.id] = (host, connection)
            connection.start(target: RexTarget(server: host.server)) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, generation == request, remoteConnections[host.id]?.0 == host else { return }
                    if case .failure = result { remoteConnections[host.id] = nil }
                    updates.send((result, host))
                }
            }
        }
    }

    @discardableResult
    func refreshHistory() -> Task<Void, Never> {
        historyTask?.cancel()
        let service = service, request = generation
        let task = Task {
            let updated = await Task.detached {
                service.recentSessionIDsByClient()
            }.value
            guard !Task.isCancelled, generation == request else { return }
            if updated != recentSessionIDs { recentSessionIDs = updated }
        }
        historyTask = task
        return task
    }

    @discardableResult
    func stop() -> [RexEventConnection] {
        generation += 1
        running = false; isConnected = false
        historyTask?.cancel(); historyTask = nil
        let connections = [connection] + remoteConnections.values.map { $0.1 }
        remoteConnections = [:]
        for connection in connections { connection.stop() }
        return connections
    }
}
