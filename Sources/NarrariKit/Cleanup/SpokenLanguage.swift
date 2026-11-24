import Foundation
import NaturalLanguage

public struct SpokenLanguage: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String

    // Below this the recognizer is unsure and clean-up runs. On 136 synthetic transcripts and their first words,
    // no answer at or above it was wrong; below it, short texts were taken for German, Catalan or Russian.
    static let confidence = 0.95

    // Nil when the recognizer is not confident.
    public static func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= confidence else { return nil }
        return best.key.rawValue
    }

    // Measured on 22-Nov-26 on clean-up replies to 128 dictations in four languages: a reply and its dictation in two
    // languages each gave the other's under 0.001; in one language the recognizer misnamed, 0.19 or more one way.
    static let otherLanguageChance = 0.01

    // True when neither text gives the other's most likely language a real chance, as with a translation.
    public static func differs(_ text: String, from other: String) -> Bool {
        let one = chances(text)
        let two = chances(other)
        guard let first = one.max(by: { $0.value < $1.value })?.key,
              let second = two.max(by: { $0.value < $1.value })?.key,
              first != second
        else { return false }
        return one[second, default: 0] < otherLanguageChance && two[first, default: 0] < otherLanguageChance
    }

    // Sentence by sentence, because the recognizer reads a two-language text whole as one language, at times neither.
    public static func words(byLanguage texts: [String]) -> [String: Int] {
        var words: [String: Int] = [:]
        let sentences = NLTokenizer(unit: .sentence)
        for text in texts {
            sentences.string = text
            sentences.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let sentence = text[range]
                if let code = detect(String(sentence)) { words[code, default: 0] += sentence.split { $0.isWhitespace }.count }
                return true
            }
        }
        return words
    }

    // Words by language over a transcript's lines; lines too short to be sure of count once as their likeliest language.
    public static func spoken(in lines: [String]) -> [String: Int] {
        let words = words(byLanguage: lines)
        guard words.isEmpty, let code = likeliest(lines.joined(separator: "\n")) else { return words }
        return [code: 1]
    }

    // The language with the most words; the lower code on a tie.
    public static func main(of words: [String: Int]) -> String? {
        words.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    // However unsure; for a text long enough to read whole, such as a reply.
    public static func likeliest(_ text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text).map(\.rawValue)
    }

    private static func chances(_ text: String) -> [NLLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 100)
    }

    // Every language the recognizer can answer with: each one the system has locales for, kept when the recognizer
    // names it back. Codes are the recognizer's own, so they match what `detect` returns.
    public static let detectable: [SpokenLanguage] = {
        var codes = Set<String>()
        for identifier in Locale.availableIdentifiers {
            let language = Locale.Language(identifier: identifier)
            guard let code = language.languageCode?.identifier else { continue }
            codes.insert(code)
            if let script = language.script?.identifier { codes.insert(code + "-" + script) }
        }
        let recognizer = NLLanguageRecognizer()
        let found = codes.filter { code in
            recognizer.reset()
            recognizer.languageConstraints = [NLLanguage(code)]
            recognizer.processString("a")
            return recognizer.dominantLanguage?.rawValue == code
        }
        return found.map { SpokenLanguage(id: $0, name: name(of: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    public static func name(of code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}
