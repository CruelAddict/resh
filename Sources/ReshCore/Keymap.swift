import Foundation

/// Rex distinguishes layout-dependent characters from W3C physical key names.
public struct KeyChord: Hashable, Sendable {
    private enum Key: Hashable, Sendable { case physical(UInt16), character(String) }
    private let key: Key
    public let modifiers: UInt8

    public init(code: UInt16, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) {
        key = .physical(code)
        modifiers = (command ? 1 : 0) | (control ? 2 : 0) | (option ? 4 : 0) | (shift ? 8 : 0)
    }
    public init(_ text: String) throws {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let name = parts.last ?? ""
        var flags: UInt8 = 0
        for part in parts.dropLast() {
            let flag: UInt8
            switch part {
            case "cmd", "command", "super", "meta", "win": flag = 1
            case "ctrl", "control": flag = 2
            case "alt", "opt", "option": flag = 4
            case "shift": flag = 8
            default: throw ReshError("Unknown modifier in \(text)")
            }
            guard flags & flag == 0 else { throw ReshError("Repeated modifier in \(text)") }
            flags |= flag
        }
        modifiers = flags
        if name.hasPrefix("["), name.hasSuffix("]"), let code = Self.codes[String(name.dropFirst().dropLast())] {
            key = .physical(code)
        } else if let code = Self.namedCodes[name] {
            key = .physical(code)
        } else if name.count == 1 {
            key = .character(name)
        } else {
            throw ReshError("Unknown key: \(text)")
        }
    }
    public func matches(code: UInt16, character: String?, modifiers: UInt8) -> Bool {
        guard self.modifiers == modifiers else { return false }
        switch key {
        case let .physical(expected): return code == expected
        case let .character(expected): return character?.lowercased() == expected
        }
    }
    public var label: String {
        let name: String
        switch key {
        case let .physical(code): name = Self.symbols[code] ?? Self.names[code]?.uppercased() ?? "?"
        case let .character(character): name = character.uppercased()
        }
        return (modifiers & 2 != 0 ? "⌃" : "") + (modifiers & 4 != 0 ? "⌥" : "")
            + (modifiers & 8 != 0 ? "⇧" : "") + (modifiers & 1 != 0 ? "⌘" : "") + name
    }
    private static let symbols: [UInt16: String] = [
        36:"↩",48:"⇥",49:"␣",51:"⌫",53:"⎋",76:"⌤",115:"↖",116:"⇞",117:"⌦",119:"↘",121:"⇟",
        123:"←",124:"→",125:"↓",126:"↑",
    ]
    private static let names: [UInt16: String] = [
        0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"o",32:"u",33:"[",34:"i",35:"p",
        36:"enter",37:"l",38:"j",39:"'",40:"k",41:";",42:"\\",43:",",44:"/",45:"n",46:"m",47:".",48:"tab",49:"space",50:"`",51:"backspace",53:"escape",
        65:"numpaddecimal",67:"numpadmultiply",69:"numpadadd",71:"numlock",75:"numpaddivide",76:"numpadenter",78:"numpadsubtract",81:"numpadequal",
        82:"numpad0",83:"numpad1",84:"numpad2",85:"numpad3",86:"numpad4",87:"numpad5",88:"numpad6",89:"numpad7",91:"numpad8",92:"numpad9",
        64:"f17",79:"f18",80:"f19",90:"f20",96:"f5",97:"f6",98:"f7",99:"f3",100:"f8",101:"f9",103:"f11",105:"f13",106:"f16",107:"f14",109:"f10",111:"f12",113:"f15",
        115:"home",116:"pageup",117:"delete",118:"f4",119:"end",120:"f2",121:"pagedown",122:"f1",123:"left",124:"right",125:"down",126:"up",
    ]
    private static let namedCodes: [String: UInt16] = {
        var result = Dictionary(uniqueKeysWithValues: names.filter { $0.value.count > 1 }.map { ($0.value, $0.key) })
        result["return"] = 36; result["esc"] = 53; result["keypadenter"] = 76
        return result
    }()
    private static let codes: [String: UInt16] = {
        var result = namedCodes
        for (code, name) in names where name.count == 1 {
            result[name.first!.isLetter ? "key" + name : name.first!.isNumber ? "digit" + name : name] = code
        }
        for (name, code) in ["equal":24,"bracketright":30,"bracketleft":33,"quote":39,"semicolon":41,"backslash":42,
                             "comma":43,"slash":44,"period":47,"backquote":50,"minus":27,"arrowleft":123,"arrowright":124,"arrowdown":125,"arrowup":126,
                             "intlbackslash":10,"intlyen":93,"intlro":94] { result[name] = UInt16(code) }
        return result
    }()
}

public enum KeyArgument: Codable, Equatable, Sendable {
    case string(String), integer(Int), boolean(Bool), other
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? c.decode(Int.self) { self = .integer(value) }
        else { self = .other }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(value): try c.encode(value)
        case let .integer(value): try c.encode(value)
        case let .boolean(value): try c.encode(value)
        case .other: try c.encodeNil()
        }
    }
}

public struct KeyInvocation: Codable, Equatable, Sendable {
    public let action: String
    public let args: [String: KeyArgument]
    public init(action: String, args: [String: KeyArgument] = [:]) { self.action = action; self.args = args }
    public var shortcut: PanelShortcut? {
        switch action {
        case "resh", "resh_dismiss": return args.isEmpty ? .dismiss : nil
        case "resh_next": return args.isEmpty ? .move(1) : nil
        case "resh_previous": return args.isEmpty ? .move(-1) : nil
        case "resh_create": return args.isEmpty ? .create : nil
        case "resh_pin": return args.isEmpty ? .pin : nil
        case "resh_delete": return args.isEmpty ? .delete : nil
        case "resh_last": return args.isEmpty ? .last : nil
        case "resh_next_source": return args.isEmpty ? .nextSource : nil
        case "resh_previous_source": return args.isEmpty ? .previousSource : nil
        case "resh_open":
            if args.isEmpty { return .open }
            if args.count == 1, case let .integer(number) = args["number"], (1...9).contains(number) { return .openResult(number) }
        case "resh_source":
            if args.count == 1, case let .string(id) = args["id"], !id.isEmpty { return .scope(SearchScope(rawValue: id)) }
        default: break
        }
        return nil
    }
    public var repeats: Bool { ["resh_next", "resh_previous", "resh_next_source", "resh_previous_source"].contains(action) }
}

/// The wire format returned by the supported client.keymap API.
public struct RexKeymap: Decodable, Sendable {
    public struct Binding: Codable, Equatable, Sendable {
        public var keys: [String]
        public var action: String
        public var args: [String: KeyArgument]?
        public var mode: String?
        public var source: String?
        public init(keys: [String], action: String, args: [String: KeyArgument]? = nil, mode: String? = "resh", source: String? = nil) {
            self.keys = keys; self.action = action; self.args = args; self.mode = mode; self.source = source
        }
    }
    public struct Mode: Decodable, Sendable {
        public let name: String
        public let exclusive: Bool
        public let blocked: [[String]]?
    }
    public struct Diagnostic: Decodable, Sendable {
        public let mode: String?
        public let source: String?
        public let message: String
    }
    public let bindings: [Binding]?
    public let modes: [Mode]?
    public let diagnostics: [Diagnostic]?
}

public struct Keymap: Equatable, Sendable {
    struct Binding: Equatable, Sendable {
        let keys: [KeyChord]
        let invocation: KeyInvocation?
        let mode: String?
        let source: String?
    }
    struct Mode: Equatable, Sendable {
        var exclusive = false
        var blocked: [[KeyChord]] = []
    }
    var bindings: [Binding] = []
    var modes: [String: Mode] = [:]
    public private(set) var diagnostics: [String] = []

    public static let defaults: Keymap = {
        var map = Keymap()
        map.modes["resh"] = Mode()
        map.bindings = defaultBindings.map {
            Binding(keys: try! $0.keys.map(KeyChord.init), invocation: KeyInvocation(action: $0.action, args: $0.args ?? [:]), mode: $0.mode, source: "resh-defaults")
        }
        return map
    }()

    public init() {}
    public init(_ response: RexKeymap) {
        let known = Set(Self.defaultBindings.map(\.action)).union(["resh", "resh_last", "resh_next_source", "resh_previous_source"])
        var relevant: Set<String> = ["resh"]
        // Only modes reachable by picker actions belong to this client.
        var previous = Set<String>()
        while previous != relevant {
            previous = relevant
            for b in response.bindings ?? [] where b.mode.map(relevant.contains) ?? false {
                if b.action == "client.mode.enter", case let .string(name) = b.args?["name"] { relevant.insert(name) }
            }
        }
        for mode in response.modes ?? [] where relevant.contains(mode.name) {
            do { modes[mode.name] = Mode(exclusive: mode.exclusive, blocked: try (mode.blocked ?? []).map { try $0.map(KeyChord.init) }) }
            catch { diagnostics.append("\(mode.name): \(error.localizedDescription)") }
        }
        for b in response.bindings ?? [] {
            let inPicker = b.mode.map(relevant.contains) ?? false
            guard inPicker || b.mode == nil && known.contains(b.action) else { continue }
            let invocation = KeyInvocation(action: b.action, args: b.args ?? [:])
            guard known.contains(b.action) || ["client.mode.enter", "client.mode.exit", "client.mode.exit_all"].contains(b.action) else {
                diagnostics.append("\(b.source ?? "Rex keymap"): action unavailable in resh: \(b.action)")
                continue
            }
            let valid: Bool
            switch invocation.action {
            case "client.mode.enter":
                if case let .string(name) = invocation.args["name"] {
                    valid = modes[name] != nil && Set(invocation.args.keys).isSubset(of: ["name", "once"])
                        && (invocation.args["once"] == nil || invocation.args["once"] == .boolean(true) || invocation.args["once"] == .boolean(false))
                } else { valid = false }
            case "client.mode.exit", "client.mode.exit_all": valid = invocation.args.isEmpty
            default: valid = invocation.shortcut != nil
            }
            if !valid { diagnostics.append("\(b.source ?? "Rex keymap"): invalid arguments for \(b.action)") }
            do {
                guard !b.keys.isEmpty else { continue }
                // An invalid invocation consumes its key rather than accidentally
                // running a lower-priority action, which might close a session.
                bindings.append(Binding(keys: try b.keys.map(KeyChord.init), invocation: valid ? invocation : nil, mode: b.mode, source: b.source))
            } catch { diagnostics.append("\(b.source ?? "Rex keymap"): \(error.localizedDescription)") }
        }
        diagnostics += (response.diagnostics ?? []).filter { $0.mode.map(relevant.contains) ?? false }
            .map { "\($0.source ?? "Rex keymap"): \($0.message)" }
    }

    public static var request: [String: Any] {
        let bindings = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultBindings))
        return ["defaults": [["name": "resh-defaults", "bindings": bindings]], "server_actions": "none"]
    }
    private static var defaultBindings: [RexKeymap.Binding] {
        var result: [RexKeymap.Binding] = []
        func bind(_ keys: [String], _ action: String, _ args: [String: KeyArgument]? = nil) {
            for key in keys { result.append(.init(keys: [key], action: action, args: args)) }
        }
        for (key, source) in [("E", SearchScope.sessions), ("A", .all), ("R", .directories), ("F", .find), ("P", .configs)] {
            bind(["cmd+[Key\(key)]"], "resh_source", ["id": .string(source.rawValue)])
        }
        bind(["cmd+shift+[KeyN]"], "resh_create")
        bind(["cmd+shift+[KeyP]"], "resh_pin")
        bind(["cmd+shift+[KeyD]"], "resh_delete")
        bind(["ctrl+[KeyN]", "down"], "resh_next")
        bind(["ctrl+[KeyP]", "up"], "resh_previous")
        bind(["tab"], "resh_next_source")
        bind(["shift+tab"], "resh_previous_source")
        bind(["enter", "[NumpadEnter]"], "resh_open")
        bind(["escape", "ctrl+[BracketLeft]"], "resh_dismiss")
        for number in 1...9 { bind(["cmd+[Digit\(number)]"], "resh_open", ["number": .integer(number)]) }
        return result
    }
    public func label(for source: SearchScope, modes: [String] = ["resh"]) -> String { label(for: .scope(source), modes: modes) }
    public func diagnostics(sources: Set<SearchScope>) -> [String] {
        diagnostics + bindings.compactMap { binding in
            guard case let .scope(source) = binding.invocation?.shortcut, !sources.contains(source) else { return nil }
            return "\(binding.source ?? "Rex keymap"): unknown resh source: \(source.rawValue)"
        }
    }
    public func label(for action: PanelShortcut, modifiers: UInt8? = nil, modes activeModes: [String] = ["resh"]) -> String {
        let candidates = entries(in: activeModes).compactMap { $0.binding }.filter { binding in
            guard binding.invocation?.shortcut == action else { return false }
            guard let modifiers else { return true }
            let primary = modifiers & 7
            return primary != 0 && binding.keys.first!.modifiers & 7 == primary
        }
        // Configuration bindings are advertised ahead of built-in alternatives.
        return candidates.sorted {
            let a = $0.source == "resh-defaults", b = $1.source == "resh-defaults"
            if a != b { return !a }
            if $0.keys.count != $1.keys.count { return $0.keys.count < $1.keys.count }
            return $0.keys.map(\.label).joined() < $1.keys.map(\.label).joined()
        }.first.map { $0.keys.map(\.label).joined(separator: " → ") } ?? ""
    }

    struct Entry { let keys: [KeyChord]; let binding: Binding? }
    func entries(in activeModes: [String]) -> [Entry] {
        var result: [Entry] = [], seen = Set<[KeyChord]>()
        for name in activeModes.reversed().map(Optional.some) + [nil] {
            for b in bindings where b.mode == name {
                if seen.insert(b.keys).inserted { result.append(Entry(keys: b.keys, binding: b)) }
            }
            if let name, let mode = modes[name] {
                for keys in mode.blocked where !keys.isEmpty {
                    if seen.insert(keys).inserted { result.append(Entry(keys: keys, binding: nil)) }
                }
                let escape = try! KeyChord("escape")
                if seen.insert([escape]).inserted {
                    let b = Binding(keys: [escape], invocation: KeyInvocation(action: "client.mode.exit"), mode: name, source: nil)
                    result.append(Entry(keys: b.keys, binding: b))
                }
                if mode.exclusive { break }
            }
        }
        // A higher-priority sequence hides the complete shortcut at its prefix,
        // and vice versa. Apply this to hints as well as keyboard dispatch.
        var prefixes: [[KeyChord]: Bool] = [:]
        return result.filter { entry in
            for length in 1...entry.keys.count {
                let prefix = Array(entry.keys.prefix(length)), continues = length < entry.keys.count
                if let existing = prefixes[prefix], existing != continues { return false }
            }
            for length in 1...entry.keys.count { prefixes[Array(entry.keys.prefix(length))] = length < entry.keys.count }
            return true
        }
    }
}
