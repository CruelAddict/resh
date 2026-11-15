import Foundation
import Testing
@testable import ReshCore

@Suite("Rex setup", .timeLimit(.minutes(1)))
struct InstallationTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let setup = root.appendingPathComponent("Sources/Resh/Resources/setup.sh")

    @Test func remoteAdapterUpdate() throws {
        let fixture = try Fixture(isRexServerRunning: true)
        let source = fixture.home.appendingPathComponent("distribution")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.setup, to: source.appendingPathComponent("setup.sh"))
        let adapter = source.appendingPathComponent("rex-actions.lua")
        let reload = fixture.home.appendingPathComponent("reload-requested")
        let arguments = [Self.root.appendingPathComponent("install.sh").path, "--remote", "--source", source.path]

        try "-- version 1\n".write(to: adapter, atomically: true, encoding: .utf8)
        try fixture.run(arguments)
        let config = try Data(contentsOf: fixture.config)
        try FileManager.default.removeItem(at: reload)

        try "-- version 2\n".write(to: adapter, atomically: true, encoding: .utf8)
        try fixture.run(arguments)

        let installed = fixture.home.appendingPathComponent(".local/share/resh/rex-actions.lua")
        #expect(try Data(contentsOf: installed) == Data(contentsOf: adapter))
        #expect(try Data(contentsOf: fixture.config) == config)
        #expect(FileManager.default.fileExists(atPath: reload.path))
    }

    @Test func setupWithRexClosed() throws {
        let fixture = try Fixture(isRexServerRunning: false)
        let customBinding = "rex.bind(\"cmd+[KeyE]\", \"custom_action\")\n"
        let original = customBinding + "\n-- >>> resh >>>\n-- previous integration\n-- <<< resh <<<\n"
        try original.write(to: fixture.config, atomically: true, encoding: .utf8)
        let arguments = [Self.setup.path, "--executable", "/usr/bin/true"]

        try fixture.run(arguments)
        let configured = try String(contentsOf: fixture.config, encoding: .utf8)
        #expect(configured.hasPrefix(customBinding))
        #expect(configured.contains(#"{ "/usr/bin/true", "print-rex-startup-lua" }"#))
        #expect(!configured.contains("previous integration"))

        try fixture.run(arguments)
        #expect(try String(contentsOf: fixture.config, encoding: .utf8) == configured)
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("init.lua.resh-backup-") }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("reload-requested").path))
    }

    private struct Fixture {
        let directory: TemporaryDirectory
        var home: URL { directory.url }
        var config: URL { home.appendingPathComponent("init.lua") }
        var rex: URL { home.appendingPathComponent("rex") }

        init(isRexServerRunning: Bool) throws {
            directory = try TemporaryDirectory()
            try """
            #!/bin/sh
            case "$*" in
                *'do -e '*) exit \(isRexServerRunning ? 0 : 1) ;;
                *'do - '*) cat >/dev/null; echo $$ ;;
                *'config check '*) exit 0 ;;
                *'config reload') touch "$HOME/reload-requested" ;;
                *) exit 1 ;;
            esac

            """.write(to: rex, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rex.path)
        }

        func run(_ arguments: [String]) throws {
            let result = try SystemCommandRunner().run("/usr/bin/env", ["HOME=\(home.path)", "PATH=/usr/bin:/bin",
                "RESH_REX_BIN=\(rex.path)", "XDG_CONFIG_HOME=\(home.path)/.config", "XDG_DATA_HOME=\(home.path)/.local/share",
                "/bin/bash"] + arguments + ["--config", config.path, "--yes"], timeout: 30)
            try #require(result.status == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
        }
    }
}
