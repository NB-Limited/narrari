import Darwin
import Foundation

// Case and accents are ignored, so "zoe" finds "Zoë".
public enum MeetingSearch {
    public struct Hit: Sendable, Equatable {
        public let meeting: Meeting
        // Where it hit, such as "Maria Petrova: The Rotterdam hub…"; nil when the title or a name matched.
        public let excerpt: String?
    }

    private static let wordsBefore = 4
    // About the first line of a list row; a hit within it needs no cut.
    private static let firstLine = 40

    public static func meetings(matching query: String, in store: MeetingStore, since: Date? = nil) async throws -> [Meeting] {
        try await hits(matching: query, in: store, since: since).map(\.meeting)
    }

    // A search the caller cancelled, such as one a newer keystroke replaced, stops with CancellationError.
    public static func hits(matching query: String, in store: MeetingStore, since: Date? = nil) async throws -> [Hit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await store.meetings(since: since).meetings.map { Hit(meeting: $0, excerpt: nil) } }
        let folded = Array(fold(query).utf8)
        var found: [Hit] = []
        for (meeting, text) in try await store.searchable(since: since) {
            try Task.checkCancellation()
            if let hit = try hit(query, folded: folded, meeting, text) { found.append(hit) }
        }
        return found
    }

    public static func contains(_ text: String, _ query: String) -> Bool {
        range(of: query, in: text) != nil
    }

    public static func range(of query: String, in text: String) -> Range<String.Index>? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    }

    // A part is read only if the one before had no hit, so a file that can't be read fails the search just where it did.
    private static func hit(_ query: String, folded: [UInt8], _ meeting: Meeting, _ text: Text) throws -> Hit? {
        let names = [meeting.title] + meeting.attendees.map(\.name) + meeting.speakers.map(\.name)
        if names.contains(where: { contains($0, query) }) { return Hit(meeting: meeting, excerpt: nil) }
        let transcript = try text.transcript.get()
        if let index = transcript.lines.first(holding: query, folded: folded) {
            let speaker = transcript.speakers[index]
            let name = meeting.speakers.first { $0.id == speaker }?.name ?? speaker
            return Hit(meeting: meeting, excerpt: "\(name): \(excerpt(of: transcript.lines.texts[index], at: query))")
        }
        for (part, label) in [(text.notes, "Notes"), (text.summary, "Summary")] {
            let lines = try part.get()
            if let index = lines.first(holding: query, folded: folded) {
                return Hit(meeting: meeting, excerpt: "\(label): \(excerpt(of: lines.texts[index], at: query))")
            }
        }
        return nil
    }

    // The same folding the search compares with, so a folded line holds the folded query whenever the line holds the query.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // A meeting's words kept in memory between searches, each part as read or the error reading it gave.
    struct Text: Sendable {
        let transcript: Result<(lines: Lines, speakers: [String]), any Error>
        let notes: Result<Lines, any Error>
        let summary: Result<Lines, any Error>

        init(transcript: () throws -> [TranscriptSegment], notes: () throws -> String, summary: () throws -> String) {
            self.transcript = Result { try transcript() }.map { (Lines($0.map(\.text)), $0.map(\.speaker)) }
            self.notes = Result { try notes() }.map(Lines.init(splitting:))
            self.summary = Result { try summary() }.map(Lines.init(splitting:))
        }
    }

    // Lines with a folded copy laid end to end, so one byte scan skips every line that can't hold the query.
    struct Lines: Sendable {
        let texts: [String]
        private let folded: [UInt8]
        private let starts: [Int]

        init(_ texts: [String]) {
            self.texts = texts
            var folded: [UInt8] = []
            var starts: [Int] = []
            for text in texts {
                starts.append(folded.count)
                folded.append(contentsOf: fold(text).utf8)
                folded.append(0)
            }
            self.folded = folded
            self.starts = starts
        }

        init(splitting text: String) {
            self.init(text.split(whereSeparator: \.isNewline).map(String.init))
        }

        // A byte match is only a candidate; the line itself decides, as the search always has.
        func first(holding query: String, folded needle: [UInt8]) -> Int? {
            guard !needle.isEmpty else { return texts.firstIndex { contains($0, query) } }
            var from = 0
            while let offset = offset(of: needle, from: from) {
                let index = line(at: offset)
                if contains(texts[index], query) { return index }
                from = index + 1 < starts.count ? starts[index + 1] : folded.count
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

    // The text from a few words before the hit, so a long line still shows it.
    private static func excerpt(of text: String, at query: String) -> String {
        guard let hit = range(of: query, in: text), text.distance(from: text.startIndex, to: hit.lowerBound) > firstLine else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        let before = text[..<hit.lowerBound].split(separator: " ", omittingEmptySubsequences: false)
        return "…" + before.suffix(wordsBefore + 1).joined(separator: " ") + text[hit.lowerBound...]
    }
}
