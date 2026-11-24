import Foundation

public enum TextDiff {
    public struct Segment: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case kept
            case removed
            case inserted
        }

        public let kind: Kind
        public let text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    // Words match when they differ only in case or punctuation, so "Maria" and "Maria," stay one kept word.
    public static func words(from heard: String, to final: String) -> [Segment] {
        let before = heard.split(whereSeparator: \.isWhitespace).map(String.init)
        let after = final.split(whereSeparator: \.isWhitespace).map(String.init)
        let difference = after.map(key).difference(from: before.map(key))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var words: [(kind: Segment.Kind, text: String)] = []
        var old = 0
        var new = 0
        while old < before.count || new < after.count {
            if old < before.count, removed.contains(old) {
                words.append((.removed, before[old]))
                old += 1
            } else if new < after.count, inserted.contains(new) {
                words.append((.inserted, after[new]))
                new += 1
            } else {
                words.append((.kept, before[old]))
                old += 1
                new += 1
            }
        }
        return merged(strikingRepeats(words))
    }

    // Of a doubled word ("the, the") either copy can be the removed one; striking the second reads as the stumble it was.
    private static func strikingRepeats(_ words: [(kind: Segment.Kind, text: String)]) -> [(kind: Segment.Kind, text: String)] {
        var words = words
        for index in words.indices.dropLast().reversed()
        where words[index].kind == .removed && words[index + 1].kind == .kept && key(words[index].text) == key(words[index + 1].text) {
            words[index].kind = .kept
            words[index + 1].kind = .removed
        }
        return words
    }

    private static func merged(_ words: [(kind: Segment.Kind, text: String)]) -> [Segment] {
        var segments: [Segment] = []
        for word in words {
            if let last = segments.last, last.kind == word.kind {
                segments[segments.count - 1] = Segment(word.kind, last.text + " " + word.text)
            } else {
                segments.append(Segment(word.kind, word.text))
            }
        }
        return segments
    }

    private static func key(_ word: String) -> String {
        let letters = word.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return letters.isEmpty ? word : String(String.UnicodeScalarView(letters))
    }
}
