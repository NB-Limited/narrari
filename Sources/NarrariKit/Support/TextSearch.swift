import Darwin
import Foundation

// Case and accents are ignored, so "zoe" finds "Zoë". The meeting and dictation searches both compare with this.
public enum TextSearch {
    // How long typing pauses before a search runs, so a burst of keys starts one search, not one per key.
    public static let typingPause = Duration.milliseconds(150)

    public static func contains(_ text: String, _ query: String) -> Bool {
        range(of: query, in: text) != nil
    }

    public static func range(of query: String, in text: String) -> Range<String.Index>? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }

    // Folds away what the comparison ignores; isFoldedFully and Needle catch the letters where the two disagree.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // Folding leaves a case or a mark the comparison ignores in a few places, such as Cherokee or a mark after a symbol, so a
    // folded copy that still holds one can't be trusted.
    static func isFoldedFully(_ folded: String) -> Bool {
        folded.unicodeScalars.allSatisfy { !$0.properties.changesWhenCaseFolded && !isMark($0) }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        [.nonspacingMark, .spacingMark, .enclosingMark].contains(scalar.properties.generalCategory)
    }

    // Latin, Greek and Cyrillic letters that fold to one and are no mark; for these the comparison is equal folds, letter by
    // letter, as a check of every pair and of three million made-up strings found.
    private static let simple: [Bool] = (0..<0x530).map { value in
        guard let scalar = Unicode.Scalar(value), !isMark(scalar) else { return false }
        let folded = fold(String(scalar)).unicodeScalars
        return folded.count == 1 && isFoldedFully(String(folded))
    }

    static func isSimple(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value < simple.count && simple[Int($0.value)] }
    }

    struct Needle: Sendable {
        let query: String
        let bytes: [UInt8]?
        let isSimple: Bool

        // The comparison matches a mark, or a letter that folds to two such as ß or ﬁ, in ways the folded bytes don't show.
        init(_ query: String) {
            self.query = query
            isSimple = TextSearch.isSimple(query)
            let folded = fold(query)
            let isPlain = isSimple
                || isFoldedFully(folded) && query.unicodeScalars.allSatisfy { !isMark($0) && fold(String($0)).unicodeScalars.count <= 1 }
            bytes = isPlain && !folded.isEmpty ? Array(folded.utf8) : nil
        }
    }

    // Lines with a folded copy laid end to end, so one byte scan skips every line that can't hold the query.
    struct Lines: Sendable {
        let texts: [String]
        private let folded: [UInt8]
        private let starts: [Int]
        private let isFoldedFully: Bool
        private let isSimple: Bool

        init(_ texts: [String]) {
            self.texts = texts
            var folded: [UInt8] = []
            var starts: [Int] = []
            var isFoldedFully = true
            var isSimple = true
            for text in texts {
                starts.append(folded.count)
                let line = fold(text)
                let isLineSimple = TextSearch.isSimple(text)
                isSimple = isSimple && isLineSimple
                isFoldedFully = isFoldedFully && (isLineSimple || TextSearch.isFoldedFully(line))
                folded.append(contentsOf: line.utf8)
                folded.append(0)
            }
            self.folded = folded
            self.starts = starts
            self.isFoldedFully = isFoldedFully
            self.isSimple = isSimple
        }

        init(splitting text: String) {
            self.init(text.split(whereSeparator: \.isNewline).map(String.init))
        }

        // A byte match is a candidate the line itself decides, unless text and query are simple and it stays inside the line.
        func first(holding needle: Needle) -> Int? {
            guard isFoldedFully, let bytes = needle.bytes else { return texts.firstIndex { contains($0, needle.query) } }
            let isSure = isSimple && needle.isSimple
            var from = 0
            while let offset = offset(of: bytes, from: from) {
                let index = line(at: offset)
                let next = index + 1 < starts.count ? starts[index + 1] : folded.count
                if isSure && offset + bytes.count < next || contains(texts[index], needle.query) { return index }
                from = next
            }
            return nil
        }

        private func offset(of needle: [UInt8], from: Int) -> Int? {
            guard from < folded.count else { return nil }
            return folded.withUnsafeBytes { hay in
                needle.withUnsafeBytes { wanted in
                    guard let base = hay.baseAddress, let found = memmem(base + from, hay.count - from, wanted.baseAddress, wanted.count) else {
                        return nil
                    }
                    return base.distance(to: UnsafeRawPointer(found))
                }
            }
        }

        private func line(at offset: Int) -> Int {
            var low = 0
            var high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return low
        }
    }
}
