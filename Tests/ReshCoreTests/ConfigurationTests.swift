import Foundation
import ReshCore
import Testing

@Suite("Configurable sources and keys")
struct ConfigurationTests {
    let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")

    @Test func defaultSourcesAndShortcuts() throws {
        let config = ReshConfiguration.defaults
        #expect(config.visibleSources.map(\.id) == [.sessions, .all, .directories, .find])
        #expect(config.keymap.action(for: try KeyChord("cmd+e")) == .scope(.sessions))
        #expect(config.keymap.action(for: try KeyChord("cmd+a")) == .scope(.all))
        #expect(config.keymap.action(for: try KeyChord("cmd+shift+p")) == .pin)
        #expect(config.keymap.action(for: try KeyChord("cmd+shift+n")) == .create)
        #expect(config.keymap.label(for: .create) == "⇧⌘N")
        #expect(config.keymap.label(for: .delete) == "⇧⌘⌫")
        for number in 1...9 {
            #expect(config.keymap.action(for: try KeyChord("cmd+\(number)")) == .openResult(number))
        }
        #expect(config.keymap.action(for: try KeyChord("ctrl+n")) == .move(1))
        #expect(config.projects.isEmpty)
    }
    @Test func namedProjectsSourcesAndOverrides() throws {
        let fixture = try TemporaryDirectory()
        let path = try fixture.folder("api")
        let config = try ReshConfiguration.parse("""
        source_order = ["work", "configs", "sessions"]
        initial_source = "work"
        [keymap]
        "ctrl+w" = "source:work"
        "cmd+1" = "none"
        [[sources]]
        id = "work"
        title = "Работа"
        type = "paths"
        paths = ["api", "api/."]
        [[session]]
        name = "Backend"
        path = "api"
        startup_command = "nvim"
        """, directory: fixture.url)
        #expect(config.initialSource.rawValue == "work")
        #expect(config.visibleSources.map(\.title) == ["Работа", "Projects", "Sessions"])
        #expect(config.keymap.action(for: try KeyChord("control+w")) == .scope(.init(rawValue: "work")))
        #expect(config.keymap.action(for: try KeyChord("cmd+1")) == nil)
        #expect(config.keymap.label(for: .init(rawValue: "work")) == "⌃W")
        let entries = try SourceLoader(tools: tools).load(.init(rawValue: "work"), configuration: config, sessions: []).entries
        #expect(entries.count == 1)
        #expect(entries.first?.displayTitle == "Backend")
        #expect(entries.first?.path == path)
        #expect(entries.first?.startupCommand == "nvim")
    }
    @Test func defaultStartupAndEmptyOverride() throws {
        let config = try ReshConfiguration.parse("""
        [default_session]
        startup_command = "nvim"
        [[session]]
        name = "one"
        path = "~/one"
        [[session]]
        name = "two"
        path = "~/two"
        startup_command = ""
        """)
        #expect(config.projects[0].startupCommand == "nvim")
        #expect(config.projects[1].startupCommand == "")
        #expect(config.visibleSources.map(\.id).contains(.configs))
    }
    @Test(arguments: [
        "source_order = []", "initial_source = 'missing'", "source_order = ['sessions', 'sessions']",
        "typo = true", "[keymap]\n'ctrl+w' = 'source:missing'", "[keymap]\n'ctrl+w' = 'explode'",
        "[keymap]\n'ctrl+1' = 'open:0'", "[keymap]\n'ctrl+1' = 'open:10'",
        "[keymap]\n'ctrl+n' = 'next'\n'control+n' = 'previous'",
        "[[sources]]\nid = 'a'\ntype = 'union'\nsources = ['a']",
        "[[sources]]\nid = 'a'\ntype = 'union'\nsources = ['b']\n[[sources]]\nid = 'b'\ntype = 'union'\nsources = ['a']",
        "[[sources]]\nid = 'a'\ntype = 'union'\nsources = ['missing']",
        "[[sources]]\nid = 'a'\ntype = 'command'\ncommand = []",
        "[[sources]]\nid = 'a'\ntype = 'paths'\ncommand = ['bad']",
        "[[sources]]\nid = 'a'\ntype = 'paths'\ntimeout = -1",
        "[[sources]]\nid = 'a'\ntype = 'command'\ncommand = ['a']\nformat = 'shell'",
        "[[sources]]\nid = 'a'\ntype = 'paths'\npaths = []\ntypo = true",
        "[[sources]]\nid = 'a'\ntype = 'paths'\n[[sources]]\nid = 'a'\ntype = 'paths'",
        "[[session]]\nname = 'a'\npath = '/a'\n[[session]]\nname = 'a'\npath = '/b'",
        "[[session]]\nname = 'a'\npath = '/a'\n[[session]]\nname = 'b'\npath = '/a/.'",
        "[[session]]\nname = ''\npath = '/a'", "[keymap\nwrong",
    ])
    func invalidConfigsAreRejected(_ text: String) {
        #expect(throws: (any Error).self) { try ReshConfiguration.parse(text) }
    }
    @Test func physicalKeysAndExactModifiersKeepNativeEditing() throws {
        let map = try Keymap(overrides: ["ctrl+t":"source:sessions", "ctrl+tab":"next_source",
            "ctrl+1":"open:1", "ctrl+shift+p":"pin", "ctrl+shift+n":"create"])
        #expect(map.action(for: KeyChord(code: 17, control: true)) == .scope(.sessions))
        #expect(map.action(for: KeyChord(code: 17, control: true, shift: true)) == nil)
        #expect(map.action(for: try KeyChord("ctrl+tab")) == .nextSource)
        #expect(map.label(for: .openResult(1), modifiers: 1) == "⌘1")
        #expect(map.label(for: .openResult(1), modifiers: 2) == "⌃1")
        #expect(map.label(for: .pin, modifiers: 2) == "⌃⇧P")
        #expect(map.action(for: try KeyChord("ctrl+shift+n")) == .create)
        #expect(map.label(for: .create, modifiers: 2) == "⌃⇧N")
        #expect(map.label(for: .openResult(1), modifiers: 0).isEmpty)
        for key in ["cmd+c", "cmd+v", "cmd+x", "cmd+z", "ctrl+a", "ctrl+f"] {
            #expect(map.action(for: try KeyChord(key)) == nil)
        }
        #expect(throws: ReshError.self) { try KeyChord("ctrl+ctrl+a") }
        #expect(throws: ReshError.self) { try KeyChord("ctrl+ф") }
    }
    @Test func commandPathsRespectCwdPreserveOrderAndDoNotUseShell() throws {
        let fixture = try TemporaryDirectory()
        let weird = "project; $(touch SHOULD_NOT_EXIST)"
        let path = try fixture.folder(weird)
        let config = try ReshConfiguration.parse("""
        [[sources]]
        id = "custom"
        type = "command"
        cwd = "."
        command = ["/usr/bin/printf", "%s\\n", '\(weird)', '\(weird)/.', 'missing']
        """, directory: fixture.url)
        let result = try SourceLoader(tools: tools).load(.init(rawValue: "custom"), configuration: config, sessions: [])
        #expect(result.entries.map(\.path) == [path])
    }
    @Test func unionPreservesSourcePriorityAndPathOrder() throws {
        let fixture = try TemporaryDirectory()
        let one = try fixture.folder("one"), two = try fixture.folder("two")
        let config = try ReshConfiguration.parse("""
        [[session]]
        name = "One"
        path = "one"
        [[sources]]
        id = "folders"
        type = "paths"
        paths = ["two", "one", "two/.", "missing"]
        [[sources]]
        id = "combined"
        type = "union"
        sources = ["configs", "folders"]
        """, directory: fixture.url)
        let entries = try SourceLoader(tools: tools).load(.init(rawValue: "combined"), configuration: config, sessions: []).entries
        #expect(entries.map(\.path) == [one, two])
        #expect(entries.map(\.kind) == [.project, .directory])
    }
    @Test func configLocationHonorsEnvironment() {
        #expect(ConfigurationFile.url(environment: ["RESH_CONFIG":"/custom/a.toml"]).path == "/custom/a.toml")
        #expect(ConfigurationFile.url(environment: ["XDG_CONFIG_HOME":"/custom"]).path == "/custom/resh/config.toml")
    }
}
