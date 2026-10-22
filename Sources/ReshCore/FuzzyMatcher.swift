import Foundation

public enum FuzzyMatcher {
    /// A subsequence matcher with bonuses for contiguous, boundary, and title matches.
    /// Every word must match. Empty queries preserve source order (zoxide's frecency).
    public static func score(_ query: String, in text: String) -> Int? {
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        if words.isEmpty { return 0 }
        let haystack = Array(normalized(text))
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
            if let range = String(haystack).range(of: String(word)), range.lowerBound == String(haystack).startIndex {
                score += 30
            }
            total += score
        }
        return total
    }

    public static func filter(_ entries: [Candidate], query: String, limit: Int = 100) -> [Candidate] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Array(entries.prefix(limit)) }
        return entries.enumerated().compactMap { index, entry -> (Candidate, Int, Int)? in
            let pathScore = score(query, in: entry.searchText)
            let titleScore = score(query, in: entry.title).map { $0 + 50 }
            guard pathScore != nil || titleScore != nil else { return nil }
            return (entry, max(pathScore ?? Int.min, titleScore ?? Int.min), index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
