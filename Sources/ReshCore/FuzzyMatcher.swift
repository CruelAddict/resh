import Foundation

public struct FuzzyMatcher: Sendable {
    public let entries: [Candidate]
    private let keys: [(text: [Character], title: [Character])]

    /// Normalize once per source snapshot, not once per row on every keystroke.
    public init(_ entries: [Candidate], reusing previous: Self? = nil) {
        self.entries = entries
        let cached = previous.map { Dictionary(zip($0.entries, $0.keys), uniquingKeysWith: { first, _ in first }) } ?? [:]
        keys = entries.map { cached[$0] ?? (Array(Self.normalized($0.searchText)), Array(Self.normalized($0.title))) }
    }

    /// A subsequence matcher with bonuses for contiguous, boundary, and title matches.
    /// Every word must match. Empty queries preserve source order (zoxide's frecency).
    private static func score(_ words: [[Character]], in haystack: [Character]) -> Int? {
        var total = 0
        for word in words {
            var previous = -2, cursor = 0, score = 0
            for letter in word {
                guard let index = (cursor..<haystack.count).first(where: { haystack[$0] == letter }) else { return nil }
                score += 10
                if index == previous + 1 { score += 14 }
                if index == 0 || "/ _-.".contains(haystack[index - 1]) { score += 18 }
                score -= min(index - cursor, 12)
                previous = index; cursor = index + 1
            }
            if haystack.starts(with: word) { score += 30 }
            total += score
        }
        return total
    }

    public func filter(query: String, limit: Int = 100) -> [Candidate] {
        let words = Self.normalized(query).split(whereSeparator: \.isWhitespace).map(Array.init)
        if words.isEmpty { return Array(entries.prefix(limit)) }
        return entries.enumerated().compactMap { index, entry -> (Candidate, Int, Int)? in
            let pathScore = Self.score(words, in: keys[index].text)
            let titleScore = Self.score(words, in: keys[index].title).map { $0 + 50 }
            guard pathScore != nil || titleScore != nil else { return nil }
            return (entry, max(pathScore ?? Int.min, titleScore ?? Int.min), index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
