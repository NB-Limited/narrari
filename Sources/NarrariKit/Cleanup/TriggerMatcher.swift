import Foundation

public enum TriggerMatcher {
    public struct Match: Sendable, Equatable {
        public let prompt: Prompt?
        public let text: String
    }

    private static let separators = CharacterSet(charactersIn: ",.:;!?-\u{2013}\u{2014}").union(.whitespacesAndNewlines)

    public static func match(_ transcript: String, prompts: [Prompt]) -> Match {
        let candidates = prompts
            .flatMap { prompt in prompt.triggers.map { (prompt: prompt, words: normalizedWords($0)) } }
            .filter { !$0.words.isEmpty }
            .sorted { $0.words.count > $1.words.count }
        guard let longest = candidates.first?.words.count else { return Match(prompt: nil, text: transcript) }

        let leading = leadingWords(of: transcript, upTo: longest)
        for candidate in candidates where candidate.words.count <= leading.count {
            guard leading.prefix(candidate.words.count).map(\.word) == candidate.words else { continue }
            let rest = remainder(of: transcript, after: leading[candidate.words.count - 1].end)
            return Match(prompt: candidate.prompt, text: capitalisedLike(transcript, rest))
        }
        return Match(prompt: nil, text: transcript)
    }

    // Two phrases with the same form here are the same trigger.
    public static func normalizedPhrase(_ text: String) -> String {
        normalizedWords(text).joined(separator: " ")
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(normalized).filter { !$0.isEmpty }
    }

    private static func normalized<S: StringProtocol>(_ word: S) -> String {
        String(word.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func leadingWords(of text: String, upTo count: Int) -> [(word: String, end: String.Index)] {
        var words: [(word: String, end: String.Index)] = []
        var index = text.startIndex
        while words.count < count, index < text.endIndex {
            guard let start = text[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            let word = normalized(text[start..<end])
            if !word.isEmpty { words.append((word, end)) }
            index = end
        }
        return words
    }

    private static func remainder(of text: String, after end: String.Index) -> String {
        let rest = text[end...]
        let start = rest.unicodeScalars.firstIndex { !separators.contains($0) } ?? rest.endIndex
        return String(text[start...])
    }

    private static func capitalisedLike(_ original: String, _ text: String) -> String {
        guard let first = text.first, original.first(where: \.isLetter)?.isUppercase == true else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
