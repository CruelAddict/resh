import Foundation

public struct SessionNamer: Sendable {
    private let runner: any CommandRunning
    private let git: String
    public init(runner: any CommandRunning = SystemCommandRunner(), git: String = "/usr/bin/git") {
        self.runner = runner; self.git = git
    }

    public func name(for path: String) -> String {
        let path = PathIdentity.canonical(path)
        func output(_ args: [String]) -> String? {
            guard let result = try? runner.run(git, ["-C", path, "rev-parse"] + args, timeout: 3), result.status == 0 else { return nil }
            return result.text.trimmingCharacters(in: .newlines)
        }
        let common = output(["--path-format=absolute", "--git-common-dir"]).map(PathIdentity.canonical)
        let root: String?
        if let common, common.hasSuffix("/.bare") {
            root = String(common.dropLast("/.bare".count))
        } else {
            root = output(["--show-toplevel"]).map(PathIdentity.canonical)
        }
        return Self.name(path: path, gitRoot: root)
    }

    /// sesh v2.17.1: git repository + relative path, otherwise the directory basename.
    public static func name(path: String, gitRoot: String?) -> String {
        var name = URL(fileURLWithPath: path).lastPathComponent
        if let root = gitRoot, path == root || path.hasPrefix(root + "/") {
            name = URL(fileURLWithPath: root).lastPathComponent + path.dropFirst(root.count)
        }
        name = name.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: ":", with: "_")
        if name.isEmpty || name == "/" { name = "root" }
        return String(name.prefix(128))
    }

}
