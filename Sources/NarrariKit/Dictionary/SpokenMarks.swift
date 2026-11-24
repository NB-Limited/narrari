import Foundation

public struct SpokenMark: Codable, Sendable, Equatable {
    public enum Mark: String, Codable, Sendable, CaseIterable {
        case lineBreak
        case paragraphBreak
        case fullStop
        case comma
        case questionMark
        case exclamationMark
        case colon

        public var text: String {
            switch self {
            case .lineBreak: "\n"
            case .paragraphBreak: "\n\n"
            case .fullStop: "."
            case .comma: ","
            case .questionMark: "?"
            case .exclamationMark: "!"
            case .colon: ":"
            }
        }

        public var name: String {
            switch self {
            case .lineBreak: "Line break"
            case .paragraphBreak: "Paragraph break"
            case .fullStop: "Full stop"
            case .comma: "Comma"
            case .questionMark: "Question mark"
            case .exclamationMark: "Exclamation mark"
            case .colon: "Colon"
            }
        }

        var isBreak: Bool { self == .lineBreak || self == .paragraphBreak }
        var endsSentence: Bool { isBreak || self == .fullStop || self == .questionMark || self == .exclamationMark }
    }

    public var phrase: String
    public var mark: Mark

    public init(phrase: String, mark: Mark) {
        self.phrase = phrase
        self.mark = mark
    }

    // Measured on 20-Nov-26 with spoken clips: the speech models often mishear "comma", "colon" and "question mark",
    // so those marks have no phrase until the user adds one.
    public static let defaults: [SpokenMark] = [
        SpokenMark(phrase: "new line", mark: .lineBreak),
        SpokenMark(phrase: "newline", mark: .lineBreak),
        SpokenMark(phrase: "new paragraph", mark: .paragraphBreak),
        SpokenMark(phrase: "period", mark: .fullStop),
        SpokenMark(phrase: "full stop", mark: .fullStop),
        SpokenMark(phrase: "exclamation mark", mark: .exclamationMark),
        SpokenMark(phrase: "exclamation point", mark: .exclamationMark)
    ]
}

// Writes each mark in place of its phrase, matched like a replacement. The speech model's own punctuation and
// spaces on both sides of a phrase go, so the spoken mark is the only one there.
public enum SpokenMarks {
    public struct Applied: Sendable, Equatable {
        public let text: String
        public let written: Int
    }

    private static let around = CharacterSet(charactersIn: ",.;:!?\u{2026}").union(.whitespacesAndNewlines)
    private static let sentenceEnds = CharacterSet(charactersIn: ".!?\u{2026}")

    public static func apply(_ marks: [SpokenMark], to text: String) -> Applied {
        let matches = Replacements.matches(of: marks.map(\.phrase), in: text)
        guard !matches.isEmpty else { return Applied(text: text, written: 0) }

        var result = ""
        var last: SpokenMark.Mark?
        var cursor = text.startIndex
        var wasSetOffAsSentence = false
        for match in matches {
            let chunk = text[cursor..<match.range.lowerBound]
            let kept = last == nil ? trimmedEnd(chunk) : trimmed(chunk)
            append(kept, after: last, lowercasing: wasSetOffAsSentence, to: &result)
            let mark = marks[match.phrase].mark
            result += mark.text
            last = mark
            let after = text[match.range.upperBound...]
            let end = after.unicodeScalars.firstIndex { !around.contains($0) } ?? text.endIndex
            wasSetOffAsSentence = text[match.range.upperBound..<end].unicodeScalars.contains { sentenceEnds.contains($0) }
            cursor = end
        }
        append(text[cursor...], after: last, lowercasing: wasSetOffAsSentence, to: &result)
        return Applied(text: result, written: matches.count)
    }

    private static func append(_ chunk: Substring, after mark: SpokenMark.Mark?, lowercasing: Bool, to result: inout String) {
        guard !chunk.isEmpty else { return }
        guard let mark else { return result += chunk }
        if !mark.isBreak { result += " " }
        if mark.endsSentence {
            result += capitalised(chunk)
        } else if lowercasing {
            result += uncapitalised(chunk)
        } else {
            result += chunk
        }
    }

    private static func trimmed(_ chunk: Substring) -> Substring {
        trimmedEnd(chunk.drop { $0.unicodeScalars.allSatisfy(around.contains) })
    }

    private static func trimmedEnd(_ chunk: Substring) -> Substring {
        var chunk = chunk
        while let last = chunk.last, last.unicodeScalars.allSatisfy(around.contains) { chunk = chunk.dropLast() }
        return chunk
    }

    private static func capitalised(_ chunk: Substring) -> String {
        guard let first = chunk.first else { return "" }
        return first.uppercased() + chunk.dropFirst()
    }

    // The speech model starts a sentence after its own full stop; after a spoken comma or colon the word goes on the
    // sentence, so a word written only with a first capital takes the case it has mid sentence.
    private static func uncapitalised(_ chunk: Substring) -> String {
        let word = chunk.prefix { $0.isLetter }
        guard word.count > 1, word.first?.isUppercase == true, !word.dropFirst().contains(where: \.isUppercase),
              let first = chunk.first
        else { return String(chunk) }
        return first.lowercased() + chunk.dropFirst()
    }
}
