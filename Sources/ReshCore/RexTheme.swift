import CoreFoundation
import Foundation

public struct RGBA: Codable, Equatable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public init?(hex: String) {
        let string = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    public var hex: String {
        String(format: "#%02x%02x%02x", Int(red * 255 + 0.5), Int(green * 255 + 0.5), Int(blue * 255 + 0.5))
    }
    static func parse(_ value: Any?) -> RGBA? {
        if let hex = value as? String { return RGBA(hex: hex) }
        guard let object = value as? [String: Any], let r = object["red"] as? Double,
              let g = object["green"] as? Double, let b = object["blue"] as? Double,
              [r, g, b].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return RGBA(red: r, green: g, blue: b, alpha: object["alpha"] as? Double ?? 1)
    }
}

public struct RexTheme: Codable, Equatable, Sendable {
    public var name: String
    public var isDark: Bool
    public var usesGlass: Bool
    public var usesTint: Bool
    public var background: RGBA
    public var foreground: RGBA
    public var selection: RGBA
    public var accent: RGBA
    public var surface: RGBA?
    public var panelBackground: RGBA { surface ?? background }

    public static func preferences() -> [String: Any] {
        let domain = "com.superlogical.rex" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyMultiple(nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    public static func read(rexApp: String, systemIsDark: Bool) -> RexTheme {
        let builtins = try? Data(contentsOf: URL(fileURLWithPath: rexApp).appendingPathComponent(
            "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"))
        return resolve(preferences: preferences(), builtins: builtins, systemIsDark: systemIsDark)
    }

    public static func resolve(preferences: [String: Any], builtins: Data?, systemIsDark: Bool) -> RexTheme {
        let appearance = preferences["Workspace.appearance"] as? String ?? "system"
        let dark = appearance == "dark" || (appearance != "light" && systemIsDark)
        let style = preferences["Workspace.interfaceStyle"] as? String ?? "modern"
        let id = preferences[dark ? "Workspace.darkThemeID" : "Workspace.lightThemeID"] as? String
        let fallbackBackground = RGBA(hex: dark ? "#18181b" : "#f4f4f5")!
        let fallbackForeground = RGBA(hex: dark ? "#f4f4f5" : "#18181b")!
        var theme = RexTheme(name: "System", isDark: dark, usesGlass: ["modern", "blendTheme"].contains(style),
            usesTint: ["useTheme", "blendTheme"].contains(style), background: fallbackBackground,
            foreground: fallbackForeground, selection: RGBA(hex: dark ? "#353542" : "#dcdce8")!,
            accent: RGBA(hex: "#9eaddb")!, surface: nil)
        let customData = preferences["Workspace.customThemes"] as? Data
        let custom = customData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let bundled = builtins.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let customEntry = custom.first { $0["id"] as? String == id }
        let bundledEntry = bundled.first { $0["id"] as? String == id }
        guard let entry = customEntry ?? bundledEntry,
              let palette = entry[customEntry == nil ? "source" : "palette"] as? [String: Any] else { return theme }
        theme.name = entry["name"] as? String ?? "Rex"
        theme.background = RGBA.parse(palette["background"]) ?? theme.background
        theme.foreground = RGBA.parse(palette["foreground"]) ?? theme.foreground
        theme.selection = RGBA.parse(palette["selectionBackground"]) ?? theme.selection
        let ansi = palette["ansi"] as? [Any] ?? []
        let semantic = entry["semantic"] as? [String: Any] ?? [:]
        theme.surface = RGBA.parse(semantic["surfaceRaised"])
        theme.accent = RGBA.parse(semantic["accentSolid"]) ?? RGBA.parse(palette["cursor"])
            ?? (ansi.count > 4 ? RGBA.parse(ansi[4]) : nil) ?? theme.accent
        // UI selection is not the terminal's text-selection background.
        theme.selection = RGBA.parse(semantic["selection"]) ?? RGBA.parse(palette["cursor"]) ?? theme.selection
        return theme
    }
}
