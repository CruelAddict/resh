import Foundation
import TOMLDecoder

public struct ProjectDefinition: Equatable, Sendable {
    public let name: String
    public let path: String
    public let startupCommand: String?
    public var candidate: Candidate {
        Candidate(id: "project:" + path, kind: .project, title: name, path: path, startupCommand: startupCommand)
    }
}

public struct SourceDefinition: Identifiable, Equatable, Sendable {
    public enum Kind: String, Decodable, Sendable { case sessions, union, zoxide, find, projects, paths, command }
    public let id: SearchScope
    public let title: String
    public let kind: Kind
    public var paths: [String] = []
    public var command: [String] = []
    public var cwd: String = FileManager.default.homeDirectoryForCurrentUser.path
    public var members: [SearchScope] = []
    public var timeout: Double = 5
}

public struct ReshConfiguration: Equatable, Sendable {
    public let sources: [SourceDefinition]
    public let visibleSources: [SourceDefinition]
    public let initialSource: SearchScope
    public let projects: [ProjectDefinition]
    public let defaultStartupCommand: String?

    public static let defaults: Self = try! parse("")

    public func source(_ id: SearchScope) -> SourceDefinition? { sources.first { $0.id == id } }
    public func project(at path: String) -> ProjectDefinition? {
        let canonical = PathIdentity.canonical(path)
        return projects.first { $0.path == canonical }
    }

    public static func parse(_ text: String, directory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Self {
        let raw = try TOMLDecoder().decode(Document.self, from: text)
        func absolute(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
            return url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        var projectNames = Set<String>(), projectPaths = Set<String>()
        let projects = try (raw.session ?? []).map { project -> ProjectDefinition in
            guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !project.path.isEmpty else { throw ReshError("Each [[session]] needs a nonempty name and path.") }
            let path = absolute(project.path)
            guard projectNames.insert(project.name).inserted, projectPaths.insert(path).inserted else {
                throw ReshError("Duplicate project name or path: \(project.name)")
            }
            return ProjectDefinition(name: project.name, path: path,
                startupCommand: project.startup_command ?? raw.default_session?.startup_command)
        }
        var sources: [SourceDefinition] = [
            .init(id: .sessions, title: "Sessions", kind: .sessions),
            .init(id: .all, title: "All", kind: .union, members: [.sessions, .configs, .directories]),
            .init(id: .directories, title: "Recent", kind: .zoxide),
            .init(id: .find, title: "Find", kind: .find, timeout: 12),
            .init(id: .configs, title: "Projects", kind: .projects),
        ]
        var declared = Set<SearchScope>()
        for source in raw.sources ?? [] {
            guard source.id.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil else {
                throw ReshError("Invalid source id: \(source.id). Use lowercase letters, digits, _ and -.")
            }
            let id = SearchScope(rawValue: source.id)
            guard declared.insert(id).inserted else { throw ReshError("Duplicate source: \(source.id)") }
            guard source.format == nil || source.format == "paths" else { throw ReshError("Source \(source.id): only format = \"paths\" is supported.") }
            guard source.timeout == nil || (source.timeout! > 0 && source.timeout! <= 60) else {
                throw ReshError("Source \(source.id): timeout must be between 0 and 60 seconds.")
            }
            let title = source.title ?? source.id
            guard !title.isEmpty else { throw ReshError("Source \(source.id) needs a title.") }
            if source.type == .command, source.command?.first?.isEmpty != false {
                throw ReshError("Source \(source.id) needs a nonempty command array.")
            }
            if source.type != .command, source.command != nil || source.cwd != nil || source.format != nil {
                throw ReshError("Source \(source.id): command, cwd and format require type = \"command\".")
            }
            if source.type != .paths, source.paths != nil { throw ReshError("Source \(source.id): paths require type = \"paths\".") }
            if source.type != .union, source.sources != nil { throw ReshError("Source \(source.id): sources require type = \"union\".") }
            let definition = SourceDefinition(id: id, title: title, kind: source.type,
                paths: (source.paths ?? []).map(absolute), command: source.command ?? [],
                cwd: source.cwd.map(absolute) ?? directory.path,
                members: (source.sources ?? []).map { SearchScope(rawValue: $0) }, timeout: source.timeout ?? 5)
            if let index = sources.firstIndex(where: { $0.id == id }) { sources[index] = definition }
            else { sources.append(definition) }
        }
        let ids = Set(sources.map(\.id))
        func validate(_ id: SearchScope, ancestors: Set<SearchScope>) throws {
            guard let source = sources.first(where: { $0.id == id }) else { throw ReshError("Unknown source: \(id.rawValue)") }
            guard !ancestors.contains(id) else { throw ReshError("Source cycle involving \(id.rawValue)") }
            for member in source.members { try validate(member, ancestors: ancestors.union([id])) }
        }
        for source in sources { try validate(source.id, ancestors: []) }
        let visibleIDs = raw.source_order?.map { SearchScope(rawValue: $0) }
            ?? sources.filter { $0.id != .configs || !projects.isEmpty || declared.contains(.configs) }.map(\.id)
        guard !visibleIDs.isEmpty, Set(visibleIDs).count == visibleIDs.count, Set(visibleIDs).isSubset(of: ids) else {
            throw ReshError("source_order must contain unique, existing source IDs and cannot be empty.")
        }
        let initial = SearchScope(rawValue: raw.initial_source ?? "sessions")
        guard visibleIDs.contains(initial) else { throw ReshError("initial_source must appear in source_order.") }
        return Self(sources: sources, visibleSources: visibleIDs.compactMap { id in sources.first { $0.id == id } },
                    initialSource: initial, projects: projects,
                    defaultStartupCommand: raw.default_session?.startup_command)
    }
}

public enum ConfigurationFile {
    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["RESH_CONFIG"] { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let root = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return root.appendingPathComponent("resh/config.toml")
    }
    public static func load(_ requestedURL: URL? = nil) throws -> ReshConfiguration {
        let url = requestedURL ?? Self.url()
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard requestedURL == nil, ProcessInfo.processInfo.environment["RESH_CONFIG"] == nil else {
                throw ReshError("Config file does not exist: \(url.path)")
            }
            return .defaults
        }
        do { return try .parse(String(contentsOf: url, encoding: .utf8), directory: url.deletingLastPathComponent()) }
        catch {
            let message = (error as? ReshError)?.message ?? String(describing: error)
            throw ReshError("\(url.path): \(message)")
        }
    }
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func rejectUnknown(_ decoder: Decoder, _ allowed: [String]) throws {
    let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
    let unknown = Set(keys).subtracting(allowed)
    if !unknown.isEmpty { throw ReshError("Unknown configuration field: \(unknown.sorted().joined(separator: ", "))") }
}
private struct Document: Decodable {
    let sources: [RawSource]?
    let session: [RawProject]?
    let source_order: [String]?
    let initial_source: String?
    let default_session: Defaults?
    enum CodingKeys: String, CodingKey, CaseIterable { case sources, session, source_order, initial_source, default_session }
    init(from decoder: Decoder) throws {
        if try decoder.container(keyedBy: AnyKey.self).allKeys.contains(where: { $0.stringValue == "keymap" }) {
            throw ReshError("Move [keymap] shortcuts to rex.bind in Rex's init.lua. See examples/config/keymap.lua, then restart resh.")
        }
        try rejectUnknown(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([RawSource].self, forKey: .sources)
        session = try c.decodeIfPresent([RawProject].self, forKey: .session)
        source_order = try c.decodeIfPresent([String].self, forKey: .source_order)
        initial_source = try c.decodeIfPresent(String.self, forKey: .initial_source)
        default_session = try c.decodeIfPresent(Defaults.self, forKey: .default_session)
    }
}
private struct RawSource: Decodable {
    let id: String
    let title: String?
    let type: SourceDefinition.Kind
    let paths: [String]?
    let command: [String]?
    let cwd: String?
    let format: String?
    let sources: [String]?
    let timeout: Double?
    enum CodingKeys: String, CodingKey, CaseIterable { case id, title, type, paths, command, cwd, format, sources, timeout }
    init(from decoder: Decoder) throws {
        try rejectUnknown(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decodeIfPresent(String.self, forKey: .title)
        type = try c.decode(SourceDefinition.Kind.self, forKey: .type)
        paths = try c.decodeIfPresent([String].self, forKey: .paths); command = try c.decodeIfPresent([String].self, forKey: .command)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd); format = try c.decodeIfPresent(String.self, forKey: .format)
        sources = try c.decodeIfPresent([String].self, forKey: .sources); timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
    }
}
private struct RawProject: Decodable {
    let name: String
    let path: String
    let startup_command: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case name, path, startup_command }
    init(from decoder: Decoder) throws {
        try rejectUnknown(decoder, CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); path = try c.decode(String.self, forKey: .path)
        startup_command = try c.decodeIfPresent(String.self, forKey: .startup_command)
    }
}
private struct Defaults: Decodable {
    let startup_command: String?
    enum CodingKeys: String, CodingKey, CaseIterable { case startup_command }
    init(from decoder: Decoder) throws {
        try rejectUnknown(decoder, CodingKeys.allCases.map(\.rawValue))
        startup_command = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .startup_command)
    }
}
