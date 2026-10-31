import Foundation

/// Input state belongs to the picker, never to the Rex server or its app client.
public struct KeymapRuntime {
    public enum Decision: Equatable { case passThrough, consumed, action(PanelShortcut) }
    private struct ActiveMode { let name: String; let once: Bool }
    private var map: Keymap
    private var stack: [ActiveMode] = []
    private var pending: [Keymap.Entry] = []
    private var depth = 0
    public var modes: [String] { stack.map(\.name) }

    public init(keymap: Keymap = .defaults) { map = keymap; reset() }
    public mutating func reset(keymap: Keymap? = nil) {
        if let keymap { map = keymap }
        stack = map.modes["resh"] == nil ? [] : [ActiveMode(name: "resh", once: false)]
        pending = []; depth = 0
    }
    public mutating func handle(code: UInt16, character: String?, modifiers: UInt8, isRepeat: Bool = false) -> Decision {
        if depth > 0, code == 53 { pending = []; depth = 0; return .consumed }
        if depth > 0, isRepeat { return .consumed }
        let entries = depth == 0 ? map.entries(in: modes) : pending
        let matching = entries.filter { $0.keys.count > depth && $0.keys[depth].matches(code: code, character: character, modifiers: modifiers) }
        guard let first = matching.first else {
            let consumed = depth > 0 || stack.contains { map.modes[$0.name]?.exclusive == true }
            pending = []; depth = 0
            return consumed ? .consumed : .passThrough
        }
        if first.keys.count > depth + 1 {
            // A prefix and a complete shortcut conflict; Rex's resolved order wins.
            pending = matching.filter { $0.keys.count > depth + 1 }
            depth += 1
            return .consumed
        }
        pending = []; depth = 0
        guard let invocation = first.binding?.invocation else { return .consumed }
        if isRepeat, !invocation.repeats { return .consumed }
        if invocation.action != "client.mode.exit", stack.last?.once == true { stack.removeLast() }
        switch invocation.action {
        case "client.mode.enter":
            if case let .string(name) = invocation.args["name"] {
                stack.append(ActiveMode(name: name, once: invocation.args["once"] == .boolean(true)))
            }
        case "client.mode.exit": if !stack.isEmpty { stack.removeLast() }
        case "client.mode.exit_all": stack = []
        default: if let shortcut = invocation.shortcut { return .action(shortcut) }
        }
        return .consumed
    }
}
