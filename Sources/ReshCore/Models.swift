import Foundation

public struct SearchScope: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let sessions = Self(rawValue: "sessions")
    public static let all = Self(rawValue: "all")
    public static let directories = Self(rawValue: "directories")
    public static let find = Self(rawValue: "find")
    public static let configs = Self(rawValue: "configs")
}

public struct Candidate: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case session, directory, project }
    public let id: String
    public let kind: Kind
    public let title: String
    public let path: String?
    public let sessionID: String?
    public let startupCommand: String?
    public let host: RexHost?

    public init(id: String, kind: Kind, title: String, path: String? = nil, sessionID: String? = nil, startupCommand: String? = nil, host: RexHost? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.path = path; self.sessionID = sessionID
        self.startupCommand = startupCommand
        self.host = host
    }
    public var hostLabel: String { host?.label ?? "This Mac" }
    public var displayTitle: String {
        kind == .directory ? path.map { host == nil ? PathIdentity.shortenHome($0) : $0 } ?? title : title
    }
    public var deduplicationID: String { path.map { Self.identity("path:" + $0, host: host) } ?? id }
    public static func identity(_ id: String, host: RexHost?) -> String { host.map { $0.id + "/" + id } ?? id }
    // Never match the common /Users/<name> prefix of every project.
    public var searchText: String {
        let path = path.map { host == nil ? PathIdentity.shortenHome($0) : $0 } ?? ""
        return (kind == .session ? title : kind == .project ? title + " " + path : displayTitle) + " " + hostLabel
    }
}

public enum PathIdentity {
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
    public static func shortenHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    public static func directories(_ paths: [String]) throws -> [Candidate] {
        var seen = Set<String>()
        return try paths.compactMap { path in
            try Task.checkCancellation()
            let canonical = canonical(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
                  isDirectory.boolValue, seen.insert(canonical).inserted else { return nil }
            return Candidate(id: "directory:" + canonical, kind: .directory,
                             title: URL(fileURLWithPath: canonical).lastPathComponent, path: canonical)
        }
    }
}
