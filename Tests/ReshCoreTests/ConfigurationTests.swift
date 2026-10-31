import Foundation
import ReshCore
import Testing

@Suite("Sources and picker shortcuts")
struct ConfigurationTests {
    let tools = Tools(rex: "/not/rex", zoxide: nil, fd: nil, rexApp: "/not/Rex.app")

    @Test func defaultSources() throws {
        let config = ReshConfiguration.defaults
        #expect(config.visibleSources.map(\.id) == [.sessions, .all, .directories, .find])
        #expect(config.visibleSources.map(\.name) == ["Sessions", "All", "Recent", "Find"])
        #expect(config.projects.isEmpty)
    }
    @Test func configurationExamples() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("examples/config")
        let examples = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "toml" }.sorted { $0.path < $1.path }
        #expect(!examples.isEmpty)
        for example in examples { _ = try ConfigurationFile.load(example) }
    }
    @Test func namedProjectsAndSources() throws {
        let fixture = try TemporaryDirectory()
        let path = try fixture.folder("api")
        let config = try ReshConfiguration.parse("""
        source_order = ["Рабочие проекты", "Projects", "Sessions"]
        initial_source = "Рабочие проекты"
        [[sources]]
        name = "Рабочие проекты"
        type = "paths"
        paths = ["api", "api/."]
        [[session]]
        name = "Backend"
        path = "api"
        startup_command = "nvim"
        """, directory: fixture.url)
        #expect(config.initialSource.rawValue == "Рабочие проекты")
        #expect(config.visibleSources.map(\.name) == ["Рабочие проекты", "Projects", "Sessions"])
        let map = try keymap("""
        {"keys":["ctrl+[KeyW]"],"action":"resh_source","args":{"name":"Рабочие проекты"},"mode":"resh"}
        """)
        var input = KeymapRuntime(keymap: map)
        #expect(map.diagnostics(sources: Set(config.sources.map(\.id))).isEmpty)
        #expect(input.handle(code: 13, character: "w", modifiers: 2) == .action(.scope(config.initialSource)))
        #expect(map.label(for: config.initialSource) == "⌃W")
        let entries = try SourceLoader(tools: tools).load(config.initialSource, configuration: config, sessions: []).entries
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
        "source_order = []", "initial_source = 'missing'", "source_order = ['Sessions', 'Sessions']",
        "source_order = ['sessions']",
        "typo = true", "[keymap]\n'ctrl+n' = 'next'",
        "[[sources]]\nname = 'a'\ntype = 'union'\nsources = ['a']",
        "[[sources]]\nname = 'a'\ntype = 'union'\nsources = ['b']\n[[sources]]\nname = 'b'\ntype = 'union'\nsources = ['a']",
        "[[sources]]\nname = 'a'\ntype = 'union'\nsources = ['missing']",
        "[[sources]]\nname = 'a'\ntype = 'command'\ncommand = []",
        "[[sources]]\nname = 'a'\ntype = 'paths'\ncommand = ['bad']",
        "[[sources]]\nname = 'a'\ntype = 'paths'\ntimeout = -1",
        "[[sources]]\nname = 'a'\ntype = 'command'\ncommand = ['a']\nformat = 'shell'",
        "[[sources]]\nname = 'a'\ntype = 'paths'\npaths = []\ntypo = true",
        "[[sources]]\nname = 'a'\ntype = 'paths'\n[[sources]]\nname = 'a'\ntype = 'paths'",
        "[[sources]]\ntype = 'paths'", "[[sources]]\nname = ''\ntype = 'paths'",
        "[[sources]]\nname = '   '\ntype = 'paths'",
        "[[sources]]\nname = 'Work'\nid = 'work'\ntype = 'paths'",
        "[[sources]]\nname = 'Work'\ntitle = 'Work projects'\ntype = 'paths'",
        "[[session]]\nname = 'a'\npath = '/a'\n[[session]]\nname = 'a'\npath = '/b'",
        "[[session]]\nname = 'a'\npath = '/a'\n[[session]]\nname = 'b'\npath = '/a/.'",
        "[[session]]\nname = ''\npath = '/a'", "[keymap\nwrong",
    ])
    func invalidConfigsAreRejected(_ text: String) {
        #expect(throws: (any Error).self) { try ReshConfiguration.parse(text) }
    }
    @Test func defaultShortcutsKeepNativeEditing() {
        let map = Keymap.defaults
        var input = KeymapRuntime(keymap: map)
        #expect(input.handle(code: 14, character: "у", modifiers: 1) == .action(.scope(.sessions)))
        #expect(input.handle(code: 14, character: "e", modifiers: 9) == .passThrough)
        #expect(input.handle(code: 48, character: nil, modifiers: 0) == .action(.nextSource))
        #expect(input.handle(code: 48, character: nil, modifiers: 8) == .action(.previousSource))
        #expect(input.handle(code: 35, character: "p", modifiers: 9) == .action(.pin))
        #expect(input.handle(code: 35, character: "p", modifiers: 9, isRepeat: true) == .consumed)
        #expect(input.handle(code: 8, character: "c", modifiers: 1) == .passThrough)
        #expect(map.label(for: .create) == "⇧⌘N")
        #expect(map.label(for: .openResult(1), modifiers: 1) == "⌘1")
    }
    @Test func characterAndPhysicalBindings() throws {
        let map = try keymap("""
        {"keys":["ctrl+[KeyJ]"],"action":"resh_next","mode":"resh"},
        {"keys":["ctrl+k"],"action":"resh_previous","mode":"resh"}
        """)
        var input = KeymapRuntime(keymap: map)
        #expect(map.diagnostics.isEmpty)
        #expect(input.handle(code: 38, character: "о", modifiers: 2) == .action(.move(1)))
        #expect(input.handle(code: 40, character: "л", modifiers: 2) == .passThrough)
        #expect(input.handle(code: 0, character: "k", modifiers: 2) == .action(.move(-1)))
        #expect(map.label(for: .move(1)) == "⌃J")
    }
    @Test func keySequencesAndReplacement() throws {
        let map = try keymap("""
        {"keys":["ctrl+b","j"],"action":"resh_next","mode":"resh"},
        {"keys":["ctrl+b","k"],"action":"resh_previous","mode":"resh"},
        {"keys":["ctrl+b"],"action":"resh_open","mode":"resh"}
        """)
        var input = KeymapRuntime(keymap: map)
        #expect(input.handle(code: 11, character: "b", modifiers: 2) == .consumed)
        #expect(input.handle(code: 38, character: "j", modifiers: 0) == .action(.move(1)))
        #expect(input.handle(code: 11, character: "b", modifiers: 2) == .consumed)
        #expect(input.handle(code: 53, character: nil, modifiers: 0) == .consumed)
        #expect(input.handle(code: 38, character: "j", modifiers: 0) == .passThrough)
        _ = input.handle(code: 11, character: "b", modifiers: 2)
        input.reset(keymap: try keymap("""
        {"keys":["j"],"action":"resh_pin","mode":"resh"}
        """))
        #expect(input.handle(code: 38, character: "j", modifiers: 0) == .action(.pin))
    }
    @Test func pickerModesAndBlockedKeys() throws {
        let map = try keymap("""
        {"keys":["ctrl+r"],"action":"client.mode.enter","args":{"name":"choose","once":true},"mode":"resh"},
        {"keys":["j"],"action":"resh_next","mode":"choose"},
        {"keys":["cmd+a"],"action":"resh_open"}
        """, modes: """
        {"name":"resh","exclusive":false,"blocked":[["cmd+a"]]},
        {"name":"choose","exclusive":true}
        """)
        var input = KeymapRuntime(keymap: map)
        #expect(input.handle(code: 0, character: "a", modifiers: 1) == .consumed)
        #expect(input.handle(code: 15, character: "r", modifiers: 2) == .consumed)
        #expect(input.handle(code: 7, character: "x", modifiers: 0) == .consumed)
        #expect(input.handle(code: 38, character: "j", modifiers: 0) == .action(.move(1)))
        #expect(input.handle(code: 38, character: "j", modifiers: 0) == .passThrough)
        _ = input.handle(code: 15, character: "r", modifiers: 2)
        #expect(input.handle(code: 53, character: nil, modifiers: 0) == .consumed)
        #expect(input.modes == ["resh"])
    }
    @Test(arguments: [false, true])
    func rexActionsInNestedModes(_ repeats: Bool) throws {
        let map = try keymap("""
        {"keys":["ctrl+r"],"action":"client.mode.enter","args":{"name":"tools"},"mode":"resh"},
        {"keys":["cmd+d"],"action":"resh_delete","mode":"resh"},
        {"keys":["cmd+d"],"action":"dev_layout","mode":"tools"}
        """, modes: """
        {"name":"resh","exclusive":false},{"name":"tools","exclusive":false}
        """, actions: """
        {"name":"dev_layout","repeats":\(repeats)}
        """)
        var input = KeymapRuntime(keymap: map)
        #expect(map.diagnostics.isEmpty)
        #expect(input.handle(code: 15, character: "r", modifiers: 2) == .consumed)
        let expected = KeymapRuntime.Decision.invoke(KeyInvocation(action: "dev_layout"))
        #expect(input.handle(code: 2, character: "d", modifiers: 1) == expected)
        #expect(input.handle(code: 2, character: "d", modifiers: 1, isRepeat: true) == (repeats ? expected : .consumed))
        #expect(map.label(for: .delete, modes: input.modes).isEmpty)
    }
    @Test func invalidActionArguments() throws {
        let map = try keymap("""
        {"keys":["ctrl+d"],"action":"resh_open","args":{"number":0},"mode":"resh"},
        {"keys":["ctrl+d"],"action":"resh_delete","mode":"resh"}
        """)
        var input = KeymapRuntime(keymap: map)
        #expect(!map.diagnostics.isEmpty)
        #expect(input.handle(code: 2, character: "d", modifiers: 2) == .consumed)
    }
    private func keymap(_ bindings: String, modes: String = #"{"name":"resh","exclusive":false}"#, actions: String = "") throws -> Keymap {
        let response = try JSONDecoder().decode(RexKeymap.self, from: Data("{\"bindings\":[\(bindings)],\"modes\":[\(modes)],\"actions\":[\(actions)]}".utf8))
        return Keymap(response)
    }
    @Test func commandPathsRespectCwdPreserveOrderAndDoNotUseShell() throws {
        let fixture = try TemporaryDirectory()
        let weird = "project; $(touch SHOULD_NOT_EXIST)"
        let path = try fixture.folder(weird)
        let config = try ReshConfiguration.parse("""
        [[sources]]
        name = "Custom"
        type = "command"
        cwd = "."
        command = ["/usr/bin/printf", "%s\\n", '\(weird)', '\(weird)/.', 'missing']
        """, directory: fixture.url)
        let result = try SourceLoader(tools: tools).load(.init(rawValue: "Custom"), configuration: config, sessions: [])
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
        name = "Work folders"
        type = "paths"
        paths = ["two", "one", "two/.", "missing"]
        [[sources]]
        name = "All"
        type = "union"
        sources = ["Projects", "Work folders"]
        """, directory: fixture.url)
        let entries = try SourceLoader(tools: tools).load(.all, configuration: config, sessions: []).entries
        #expect(entries.map(\.path) == [one, two])
        #expect(entries.map(\.kind) == [.project, .directory])
    }
    @Test func configLocationHonorsEnvironment() {
        #expect(ConfigurationFile.url(environment: ["RESH_CONFIG":"/custom/a.toml"]).path == "/custom/a.toml")
        #expect(ConfigurationFile.url(environment: ["XDG_CONFIG_HOME":"/custom"]).path == "/custom/resh/config.toml")
    }
}
