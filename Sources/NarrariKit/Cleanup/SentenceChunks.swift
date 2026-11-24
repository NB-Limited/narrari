import Foundation
import NaturalLanguage

// A text cut into runs of whole sentences of at most `maxWords` words each, never across a line break; a longer
// sentence stays one piece.
public struct SentenceChunks: Sendable, Equatable {
    public let pieces: [String]
    // The text before each piece and, last, after the final one, so joining the pieces rebuilds the text exactly.
    public let gaps: [String]

    public init(_ text: String, maxWords: Int) {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var groups: [Range<String.Index>] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let lineRange = line.startIndex..<line.endIndex
            var open: Range<String.Index>?
            var words = 0
            tokenizer.enumerateTokens(in: lineRange) { range, _ in
                guard let sentence = Self.trimmed(range.clamped(to: lineRange), in: text) else { return true }
                let count = Self.wordCount(text[sentence])
                if let group = open, words + count <= maxWords {
                    open = group.lowerBound..<sentence.upperBound
                    words += count
                } else {
                    if let group = open { groups.append(group) }
                    open = sentence
                    words = count
                }
                return true
            }
            if let open { groups.append(open) }
        }
        var cursor = text.startIndex
        var gaps: [String] = []
        for group in groups {
            gaps.append(String(text[cursor..<group.lowerBound]))
            cursor = group.upperBound
        }
        gaps.append(String(text[cursor...]))
        pieces = groups.map { String(text[$0]) }
        self.gaps = gaps
    }

    // A reply laid out in lines, as Agent brief writes a list, gets lines of its own so the next run is not glued to its last item.
    public func joined(_ replies: [String]) -> String {
        var text = ""
        for (index, reply) in replies.enumerated() {
            let isLaidOut = index > 0 && [replies[index - 1], reply].contains { $0.contains("\n") || $0.hasPrefix("- ") }
            text += (isLaidOut && !gaps[index].contains(where: \.isNewline) ? "\n" : gaps[index]) + reply
        }
        return text + (gaps.last ?? "")
    }

    public static func wordCount(_ text: Substring) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    private static func trimmed(_ range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        guard let start = text[range].firstIndex(where: { !$0.isWhitespace }),
              let end = text[range].lastIndex(where: { !$0.isWhitespace }) else { return nil }
        return start..<text.index(after: end)
    }
}
