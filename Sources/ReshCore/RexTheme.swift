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
    private static let cache = RexThemeCache()
    public var name: String
    public var isDark: Bool
    public var usesGlass: Bool
    public var usesTint: Bool
    public var background: RGBA
    public var foreground: RGBA
    public var selection: RGBA
    public var accent: RGBA
    public var surface: RGBA
    public var info: RGBA
    public var attentionColor: RGBA { info }
    public var panelBackground: RGBA { surface }

    public static func fallback(systemIsDark: Bool) -> RexTheme {
        let background = systemIsDark ? RGBA(red: 0.12, green: 0.12, blue: 0.12) : RGBA(red: 0.94, green: 0.94, blue: 0.94)
        let foreground = systemIsDark ? RGBA(red: 0.95, green: 0.95, blue: 0.95) : RGBA(red: 0.1, green: 0.1, blue: 0.1)
        let selection = systemIsDark ? RGBA(red: 0.3, green: 0.3, blue: 0.3) : RGBA(red: 0.78, green: 0.84, blue: 0.94)
        let accent = RGBA(red: 0.04, green: 0.52, blue: 1)
        return RexTheme(name: "System", isDark: systemIsDark, usesGlass: true, usesTint: false,
            background: background, foreground: foreground,
            selection: selection, accent: accent, surface: background, info: accent)
    }

    public static func preferences(keys: [String]? = nil) -> [String: Any] {
        let domain = "com.superlogical.rex" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyMultiple(keys.map { $0 as CFArray }, domain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    public static func read(rexApp: String, systemIsDark: Bool) throws -> RexTheme {
        let url = URL(fileURLWithPath: rexApp).appendingPathComponent(
            "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json")
        return try cache.read(url: url, preferences: preferences(keys: ["Workspace.appearance", "Workspace.interfaceStyle",
            "Workspace.darkThemeID", "Workspace.lightThemeID", "Workspace.customThemes"]), systemIsDark: systemIsDark)
    }

    public static func resolve(preferences: [String: Any], builtins: Data?, systemIsDark: Bool) throws -> RexTheme {
        let appearance = preferences["Workspace.appearance"] as? String ?? "system"
        let dark = appearance == "dark" || (appearance != "light" && systemIsDark)
        let style = preferences["Workspace.interfaceStyle"] as? String ?? "modern"
        guard ["system", "light", "dark"].contains(appearance),
              ["modern", "classic", "blendTheme", "useTheme"].contains(style) else {
            throw ReshError("Unsupported Rex appearance or interface style.")
        }
        guard let id = preferences[dark ? "Workspace.darkThemeID" : "Workspace.lightThemeID"] as? String else {
            throw ReshError("Rex's selected theme is unavailable. Select a theme in Rex Settings.")
        }
        func entries(_ data: Data?) throws -> [[String: Any]] {
            guard let data else { return [] }
            guard let value = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ReshError("Unsupported Rex theme data.")
            }
            return value
        }
        let customData = preferences["Workspace.customThemes"] as? Data
        let custom = try entries(customData), bundled = try entries(builtins)
        let customEntry = custom.first { $0["id"] as? String == id }
        let bundledEntry = bundled.first { $0["id"] as? String == id }
        guard let entry = customEntry ?? bundledEntry,
              let palette = entry[customEntry == nil ? "source" : "palette"] as? [String: Any] else {
            throw ReshError("Cannot read selected Rex theme ‘\(id)’.")
        }
        func color(_ value: Any?, _ name: String) throws -> RGBA {
            guard let color = RGBA.parse(value) else { throw ReshError("Rex theme ‘\(id)’ has no valid \(name) color.") }
            return color
        }
        let background = try color(palette["background"], "background")
        let foreground = try color(palette["foreground"], "foreground")
        let selection: RGBA, accent: RGBA, surface: RGBA, info: RGBA
        if customEntry != nil {
            // Imported themes supply a terminal palette rather than bundled UI tokens.
            accent = try color(palette["cursor"], "cursor")
            selection = try color(palette["selectionBackground"], "selectionBackground")
            surface = background
            guard let ansi = palette["ansi"] as? [Any], ansi.count > 4 else {
                throw ReshError("Rex theme ‘\(id)’ has no ANSI palette.")
            }
            info = try color(ansi[4], "ANSI blue")
        } else {
            let semantic = entry["semantic"] as? [String: Any] ?? [:]
            accent = try color(semantic["accentSolid"], "accentSolid")
            selection = try color(semantic["selection"], "selection")
            surface = try color(semantic["surfaceRaised"], "surfaceRaised")
            info = try color(semantic["infoSolid"], "infoSolid")
        }
        return RexTheme(name: entry["name"] as? String ?? id, isDark: dark,
            usesGlass: ["modern", "blendTheme"].contains(style), usesTint: ["useTheme", "blendTheme"].contains(style),
            background: background, foreground: foreground, selection: selection, accent: accent, surface: surface, info: info)
    }
}

/// Retain only the selected palette and its inputs, not the full parsed theme
/// catalog. Unchanged refreshes stat the file but do not read or parse it again.
final class RexThemeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var attributes: NSDictionary?
    private var preferences: NSDictionary?
    private var dark = false
    private var theme: RexTheme?

    func read(url: URL, preferences: [String: Any], systemIsDark: Bool) throws -> RexTheme {
        let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
        let relevant = metadata.filter { [.modificationDate, .size, .systemFileNumber].contains($0.key) } as NSDictionary
        let selection = preferences as NSDictionary
        lock.lock(); defer { lock.unlock() }
        if self.url == url, attributes == relevant, self.preferences == selection, dark == systemIsDark, let theme { return theme }
        let updated = try RexTheme.resolve(preferences: preferences, builtins: Data(contentsOf: url), systemIsDark: systemIsDark)
        self.url = url; attributes = relevant; self.preferences = selection; dark = systemIsDark; theme = updated
        return updated
    }
}
