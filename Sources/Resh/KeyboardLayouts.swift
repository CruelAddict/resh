import Carbon
import Foundation

struct KeyboardLayouts: Sendable {
    private let mappings: [[Character: Character]]

    /// Each layout lists characters at the same physical key and modifier positions.
    init(_ layouts: [[String]]) {
        var mappings: [[Character: Character]] = []
        for (index, source) in layouts.enumerated() {
            for (other, target) in layouts.enumerated() where index != other {
                var mapping: [Character: Character] = [:]
                for (from, to) in zip(source, target) where from.count == 1 && to.count == 1 {
                    let character = from.first!
                    if !character.isWhitespace, mapping[character] == nil { mapping[character] = to.first! }
                }
                if !mapping.isEmpty { mappings.append(mapping) }
            }
        }
        self.mappings = mappings
    }

    func alternatives(for query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        // Translate before fuzzy normalization, which folds letters such as й into и.
        var seen: Set<String> = [query]
        return mappings.compactMap { mapping in
            let translated = String(query.map { mapping[$0] ?? $0 })
            return seen.insert(translated).inserted ? translated : nil
        }
    }

    @MainActor static func enabled() -> Self {
        // IMEs compose text and do not expose Unicode keyboard layout data.
        let properties = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary
        let sources = TISCreateInputSourceList(properties, false).takeRetainedValue() as! [TISInputSource]
        let keyboardType = UInt32(LMGetKbdType())
        let layouts = sources.compactMap { source -> [String]? in
            guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { return nil }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            return [UInt32(0), UInt32(shiftKey >> 8)].flatMap { modifiers in
                (0..<128).map { keyCode -> String in
                    var state: UInt32 = 0, length = 0
                    var characters = [UniChar](repeating: 0, count: 255)
                    let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifiers,
                        keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask), &state,
                        characters.count, &length, &characters)
                    guard status == noErr, length > 0 else { return "" }
                    let text = String(utf16CodeUnits: characters, count: length)
                    return text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "" : text
                }
            }
        }
        return Self(layouts)
    }
}
