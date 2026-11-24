import Foundation
import NarrariKit
import NaturalLanguage

// A dictation cut into runs of whole sentences of at most `maxWords` words each; a longer sentence stays one piece.
public struct SentenceChunks: Sendable, Equatable {
    public let pieces: [String]
    // The text before each piece and, last, after the final one, so joining rebuilds the dictation exactly.
    public let gaps: [String]

    public init(_ text: String, maxWords: Int) {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var groups: [Range<String.Index>] = []
        var words = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            guard let sentence = Self.trimmed(range, in: text) else { return true }
            let count = Self.wordCount(text[sentence])
            if let last = groups.last, words + count <= maxWords {
                groups[groups.count - 1] = last.lowerBound..<sentence.upperBound
                words += count
            } else {
                groups.append(sentence)
                words = count
            }
            return true
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

    public func joined(_ replies: [String]) -> String {
        zip(gaps, replies).map { $0 + $1 }.joined() + (gaps.last ?? "")
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

// Cleans each run of sentences alone, so one reply turned down keeps only its own words as heard.
public struct ChunkedCleanup: Sendable {
    public struct Outcome: Sendable {
        public let text: String
        public let chunks: SentenceChunks
        public let results: [CleanupResult]
    }

    private let service: CleanupService
    private let maxWords: Int

    public init(service: CleanupService, maxWords: Int) {
        self.service = service
        self.maxWords = maxWords
    }

    public func clean(_ transcript: String, with prompt: Prompt, spellings: [String] = []) async -> Outcome {
        let chunks = SentenceChunks(transcript, maxWords: maxWords)
        var results: [CleanupResult] = []
        for piece in chunks.pieces {
            results.append(await service.clean(piece, with: prompt, spellings: spellings))
        }
        return Outcome(text: chunks.joined(results.map(\.text)), chunks: chunks, results: results)
    }
}
