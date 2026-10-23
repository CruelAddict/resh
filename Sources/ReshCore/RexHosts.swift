import Foundation

/// A saved Rex host, not server.status.host_id (which describes shared files).
public struct RexHost: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let endpoints: [String]

    public init(id: String, label: String, endpoints: [String]) {
        self.id = id; self.label = label; self.endpoints = endpoints
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decode(String.self, forKey: .label)
        endpoints = try values.decode([String].self, forKey: .endpoints)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? "host:" + label
        guard !label.isEmpty, !endpoints.isEmpty else { throw ReshError("Rex returned an invalid host.") }
    }

    // Let the supported CLI resolve the saved label, including endpoint failover.
    public var server: String { label }
}

public struct RexHostCatalog: Sendable {
    public let client: RexClient
    public init(client: RexClient) { self.client = client }

    public func read() throws -> (hosts: [RexHost], warnings: [String]) {
        struct Entry: Decodable { let host: RexHost }
        struct Reply: Decodable { let hosts: [Entry]; let warnings: [String]? }
        let reply = try JSONDecoder().decode(Reply.self, from: client.command(["hosts", "--json"], timeout: 2))
        var seen = Set<String>(), endpoints = Set<String>()
        let hosts = reply.hosts.map(\.host).filter { host in
            guard seen.insert(host.id).inserted, endpoints.isDisjoint(with: host.endpoints) else { return false }
            endpoints.formUnion(host.endpoints)
            return true
        }
        return (hosts, reply.warnings ?? [])
    }
}

/// The optional, versioned Lua adapter. Session listing never depends on it.
public struct RexRemote: Sendable {
    public let client: RexClient
    public init(client: RexClient) { self.client = client }

    public func functions(timeout: TimeInterval = 2) throws -> Set<String> {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        struct Action: Decodable { let name: String; let kind: String? }
        struct Actions: Decodable { let actions: [Action] }
        let actions = try JSONDecoder().decode(Actions.self, from: client.command(["actions", "--json"], timeout: timeout))
        let names = Set(actions.actions.filter { $0.kind == "lua" }.map(\.name))
        guard names.contains("resh_info") else { return [] }
        guard names.contains("resh_query") else { throw ReshError("Incomplete resh integration: resh_query is missing.") }
        struct Info: Decodable { let version: Int; let functions: [String] }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ReshError("The resh integration check timed out.") }
        let info = try JSONDecoder().decode(Info.self, from: client.command(["do", "resh_info", "--json"], timeout: remaining))
        guard info.version == 1 else { throw ReshError("Unsupported resh integration version: \(info.version). Expected 1.") }
        return Set(info.functions)
    }

    public func paths(function: String, host: RexHost) throws -> [Candidate] {
        struct Reply: Decodable { let results: [String]? }
        let reply = try JSONDecoder().decode(Reply.self, from: query(function: function))
        let paths = reply.results ?? []
        guard paths.count <= 20_000 else { throw ReshError("Remote source exceeded 20,000 results.") }
        var seen = Set<String>()
        return try paths.compactMap { value in
            var path = value
            guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n") else {
                throw ReshError("Remote source returned a non-absolute or invalid path.")
            }
            // fd appends a separator to directories. Normalize it lexically,
            // without asking the Mac to resolve a remote path or symlink.
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard seen.insert(path).inserted else { return nil }
            return Candidate(id: Candidate.identity("directory:" + path, host: host), kind: .directory,
                title: path.split(separator: "/").last.map(String.init) ?? path, path: path, host: host)
        }
    }

    public struct Directory: Decodable, Sendable {
        public let path: String
        public let gitRoot: String?
        public var name: String { SessionNamer.name(path: path, gitRoot: gitRoot) }
        private enum CodingKeys: String, CodingKey { case path, gitRoot = "git_root" }
    }
    public func directory(_ path: String) throws -> Directory {
        struct Reply: Decodable { let results: Directory }
        let reply = try JSONDecoder().decode(Reply.self, from: query(function: "resolve", arguments: ["path": path]))
        guard reply.results.path.hasPrefix("/"), !reply.results.path.contains("\0"), !reply.results.name.isEmpty else {
            throw ReshError("Remote integration returned an invalid directory.")
        }
        return reply.results
    }

    private func query(function: String, arguments: [String: String] = [:]) throws -> Data {
        var arguments = arguments
        arguments["fn"] = function
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return try client.command(["do", "resh_query", "--args", json, "--json"], timeout: 5)
    }
}
