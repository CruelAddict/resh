import AppKit

@MainActor
final class RexAgentIcons {
    private let bundle: Bundle?
    private var images: [String: NSImage] = [:]
    private lazy var fallback = load("rex") ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)

    init(rexApp: String) {
        bundle = Bundle(path: rexApp + "/Contents/Resources/SuperBlockIcons_SuperBlockIcons.bundle")
    }

    func image(for app: String) -> NSImage? {
        let name = app.lowercased() == "claude-code" ? "claude" : app.lowercased()
        if let image = images[name] { return image }
        let image = load(name) ?? fallback
        images[name] = image
        return image
    }

    private func load(_ name: String) -> NSImage? {
        let image = bundle?.image(forResource: "block-glyph-" + name)?.copy() as? NSImage
        image?.isTemplate = true
        return image
    }
}
