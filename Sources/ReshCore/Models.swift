import Foundation

public enum SearchScope: String, CaseIterable, Sendable {
    case sessions, all, directories, find
    public var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .all: return "All"
        case .directories: return "Recent folders"
        case .find: return "Find folders"
        }
    }
    public var shortcut: String {
        switch self { case .sessions: return "⌃T"; case .all: return "⌃A"; case .directories: return "⌃X"; case .find: return "⌃F" }
    }
}

public struct Candidate: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case session, directory }
    public let id: String
    public let kind: Kind
    public let title: String
    public let path: String?
    public let sessionID: String?

    public init(id: String, kind: Kind, title: String, path: String? = nil, sessionID: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.path = path; self.sessionID = sessionID
    }
    public var subtitle: String { path.map(PathIdentity.shortenHome) ?? "Running Rex session" }
    // Never match the common /Users/<name> prefix of every project.
    public var searchText: String { path.map(PathIdentity.shortenHome) ?? title }
}

public struct Catalog: Sendable {
    public var sessions: [Candidate]
    public var directories: [Candidate]
    public var warnings: [String]
    public init(sessions: [Candidate] = [], directories: [Candidate] = [], warnings: [String] = []) {
        self.sessions = sessions; self.directories = directories; self.warnings = warnings
    }
    public func entries(for scope: SearchScope) -> [Candidate] {
        switch scope {
        case .sessions: return sessions
        case .directories, .find: return directories
        case .all:
            let runningPaths = Set(sessions.compactMap(\.path))
            return sessions + directories.filter { !runningPaths.contains($0.path ?? "") }
        }
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
    public static func directories(_ paths: [String]) -> [Candidate] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let canonical = canonical(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
                  isDirectory.boolValue, seen.insert(canonical).inserted else { return nil }
            return Candidate(id: "directory:" + canonical, kind: .directory,
                             title: URL(fileURLWithPath: canonical).lastPathComponent, path: canonical)
        }
    }
}
