import Foundation

// A phrase matches whole words only, ignoring case, with any run of spaces in the text standing for one space
// in the phrase. Punctuation next to the phrase is not part of the match and stays where it was.
public enum Replacements {
    struct Match {
        let range: Range<String.Index>
        // The phrase's index in the list it was matched from.
        let phrase: Int
    }

    // Two phrases with the same form here match the same words.
    public static func normalizedPhrase(_ phrase: String) -> String {
        phrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func apply(_ replacements: [Replacement], to text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for match in matches(of: replacements.map(\.phrase), in: text) {
            result += text[cursor..<match.range.lowerBound] + replacements[match.phrase].text
            cursor = match.range.upperBound
        }
        return result + text[cursor...]
    }

    // In text order, the longest phrase first where two could match at the same place.
    static func matches(of phrases: [String], in text: String) -> [Match] {
        let usable = phrases.enumerated()
            .map { (index: $0.offset, words: $0.element.split(whereSeparator: \.isWhitespace)) }
            .filter { !$0.words.isEmpty }
            .sorted { $0.words.joined(separator: " ").count > $1.words.joined(separator: " ").count }
        guard !usable.isEmpty else { return [] }

        let alternatives = usable.map { phrase in
            "(" + phrase.words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+") + ")"
        }
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            Log.failure("replacements-pattern")
            return []
        }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard
                let group = (1...usable.count).first(where: { match.range(at: $0).location != NSNotFound }),
                let range = Range(match.range, in: text)
            else { return nil }
            return Match(range: range, phrase: usable[group - 1].index)
        }
    }
}
