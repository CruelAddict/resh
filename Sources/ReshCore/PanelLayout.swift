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
    case scope(SearchScope), move(Int), open, openResult(Int), create, pin, dismiss, delete, last, nextSource, previousSource
}
