import Foundation

/// US hardware positions, not translated characters. A binding keeps working in Russian.
public struct KeyChord: Hashable, Sendable {
    public let code: UInt16
    public let modifiers: UInt8
    public init(code: UInt16, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) {
        self.code = code
        modifiers = (command ? 1 : 0) | (control ? 2 : 0) | (option ? 4 : 0) | (shift ? 8 : 0)
    }
    public init(_ text: String) throws {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, let code = Self.codes[key] else { throw ReshError("Unknown key: \(text)") }
        var flags: UInt8 = 0
        for part in parts.dropLast() {
            let flag: UInt8
            switch part {
            case "cmd", "command", "super": flag = 1
            case "ctrl", "control": flag = 2
            case "alt", "opt", "option": flag = 4
            case "shift": flag = 8
            default: throw ReshError("Unknown modifier in \(text)")
            }
            guard flags & flag == 0 else { throw ReshError("Repeated modifier in \(text)") }
            flags |= flag
        }
        self.code = code; modifiers = flags
    }
    public var label: String {
        let key = Self.symbols[code] ?? Self.names[code]?.uppercased() ?? "?"
        return (modifiers & 2 != 0 ? "⌃" : "") + (modifiers & 4 != 0 ? "⌥" : "")
            + (modifiers & 8 != 0 ? "⇧" : "") + (modifiers & 1 != 0 ? "⌘" : "") + key
    }
    private static let symbols: [UInt16: String] = [
        36:"↩",48:"⇥",49:"␣",51:"⌫",53:"⎋",76:"⌤",115:"↖",116:"⇞",117:"⌦",119:"↘",121:"⇟",
        123:"←",124:"→",125:"↓",126:"↑",
    ]
    private static let names: [UInt16: String] = [
        0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"o",32:"u",33:"[",34:"i",35:"p",
        36:"enter",37:"l",38:"j",39:"'",40:"k",41:";",42:"\\",43:",",44:"/",45:"n",46:"m",47:".",48:"tab",49:"space",50:"`",51:"backspace",53:"escape",
        76:"keypadenter",96:"f5",97:"f6",98:"f7",99:"f3",100:"f8",101:"f9",103:"f11",109:"f10",111:"f12",115:"home",116:"pageup",117:"delete",118:"f4",119:"end",120:"f2",121:"pagedown",122:"f1",123:"left",124:"right",125:"down",126:"up",
    ]
    private static let codes: [String: UInt16] = {
        var result = Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) })
        result["return"] = 36; result["esc"] = 53
        return result
    }()
}

public struct Keymap: Equatable, Sendable {
    private var bindings: [KeyChord: PanelShortcut] = [:]
    private var customized: [KeyChord] = []
    public init(overrides: [String: String] = [:], sources: Set<SearchScope> = [.sessions, .all, .directories, .find]) throws {
        let defaults: [String: PanelShortcut] = [
            "cmd+e":.scope(.sessions), "cmd+a":.scope(.all), "cmd+r":.scope(.directories),
            "cmd+f":.scope(.find), "cmd+p":.scope(.configs), "cmd+shift+n":.create, "cmd+shift+p":.pin,
            "cmd+s":.ignore, "cmd+shift+d":.delete,
            "ctrl+n":.move(1), "ctrl+p":.move(-1), "down":.move(1), "up":.move(-1),
            "tab":.nextSource, "shift+tab":.previousSource, "enter":.open, "keypadenter":.open, "escape":.dismiss,
            "ctrl+[":.dismiss,
        ]
        for (key, action) in defaults { bindings[try KeyChord(key)] = action }
        for number in 1...9 { bindings[try KeyChord("cmd+\(number)")] = .openResult(number) }
        var seen = Set<KeyChord>()
        for key in overrides.keys.sorted() {
            let chord = try KeyChord(key)
            guard seen.insert(chord).inserted else { throw ReshError("Duplicate key binding: \(key)") }
            customized.append(chord)
            let value = overrides[key]!
            let action: PanelShortcut?
            switch value {
            case "none": action = nil
            case "next": action = .move(1)
            case "previous": action = .move(-1)
            case "open": action = .open
            case "create": action = .create
            case "pin": action = .pin
            case "dismiss": action = .dismiss
            case "delete": action = .delete
            case "next_source": action = .nextSource
            case "previous_source": action = .previousSource
            default:
                if value.hasPrefix("open:"), let number = Int(value.dropFirst(5)), (1...9).contains(number) {
                    action = .openResult(number)
                    break
                }
                guard value.hasPrefix("source:") else { throw ReshError("Unknown action for \(key): \(value)") }
                let source = SearchScope(rawValue: String(value.dropFirst(7)))
                guard sources.contains(source) else { throw ReshError("Unknown source for \(key): \(source.rawValue)") }
                action = .scope(source)
            }
            bindings[chord] = action
        }
    }
    public func action(for chord: KeyChord) -> PanelShortcut? { bindings[chord] }
    public func label(for source: SearchScope) -> String {
        label(for: .scope(source))
    }
    /// Shift may complete an advertised chord; the held primary modifiers select
    /// the hint family (Cmd, Ctrl, Option, or their combination).
    public func label(for action: PanelShortcut, modifiers: UInt8? = nil) -> String {
        func matches(_ key: KeyChord) -> Bool {
            guard bindings[key] == action else { return false }
            guard let modifiers else { return true }
            let primary = modifiers & 7
            return primary != 0 && key.modifiers & 7 == primary
        }
        if let key = customized.first(where: matches) { return key.label }
        return bindings.keys.filter(matches).map(\.label).sorted().first ?? ""
    }
}
