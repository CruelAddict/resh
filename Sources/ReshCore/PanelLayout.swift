import Foundation

public enum PanelLayout {
    public static let width: CGFloat = 560
    public static let rowHeight: CGFloat = 26
    public static let outerPadding: CGFloat = 8
    public static let sectionGap: CGFloat = 8
    public static let searchHeight: CGFloat = 32
    public static let sourcesHeight: CGFloat = 22
    public static let sourcesTop = outerPadding + searchHeight + sectionGap
    public static let listTop = sourcesTop + sourcesHeight + sectionGap
    public static let maximumVisibleRows = 12

    public static func listHeight(resultCount: Int) -> CGFloat {
        CGFloat(min(maximumVisibleRows, max(1, resultCount))) * rowHeight
    }
    public static func height(resultCount: Int, hasError: Bool = false) -> CGFloat {
        listTop + listHeight(resultCount: resultCount) + outerPadding + (hasError ? 44 : 0)
    }
}

public enum PanelShortcut: Equatable, Sendable {
    case scope(SearchScope), move(Int), open, dismiss, delete, ignore
    public static let launcherKeyCode: UInt16 = 1
    public static func launcherIsEnabled(frontmostBundleID: String?) -> Bool {
        frontmostBundleID == "com.superlogical.rex"
    }

    /// Hardware key positions, not translated characters: independent of input layout.
    public static func action(keyCode: UInt16, command: Bool = false, control: Bool = false,
                              option: Bool = false, shift: Bool = false) -> PanelShortcut? {
        guard !option else { return nil }
        if command {
            guard !control else { return nil }
            if shift { return keyCode == 51 ? .delete : nil }
            switch keyCode {
            case 18: return .scope(.sessions)    // ⌘1
            case 19: return .scope(.all)         // ⌘2
            case 20: return .scope(.directories) // ⌘3
            case 21: return .scope(.find)        // ⌘4
            case launcherKeyCode: return .ignore // ⌘S, already in the picker
            default: return nil                // Native select-all, copy/paste, undo, etc.
            }
        }
        if control {
            switch keyCode { case 45: return .move(1); case 35: return .move(-1); default: return nil }
        }
        switch keyCode {
        case 53: return .dismiss
        case 125: return .move(1)
        case 126: return .move(-1)
        case 48: return .move(shift ? -1 : 1)
        case 36, 76: return .open
        default: return nil
        }
    }
}
