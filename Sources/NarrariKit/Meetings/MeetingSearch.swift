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
        let needle = TextSearch.Needle(query)
        var found: [Hit] = []
        for (meeting, text) in try await store.searchable(since: since) {
            try Task.checkCancellation()
            if let hit = try hit(needle, meeting, text) { found.append(hit) }
        }
        return found
    }

    public static func contains(_ text: String, _ query: String) -> Bool {
        TextSearch.contains(text, query)
    }

    public static func range(of query: String, in text: String) -> Range<String.Index>? {
        TextSearch.range(of: query, in: text)
    }

    // A part is read only if the one before had no hit, so a file that can't be read fails the search just where it did.
    private static func hit(_ needle: TextSearch.Needle, _ meeting: Meeting, _ text: Text) throws -> Hit? {
        let query = needle.query
        let names = [meeting.title] + meeting.attendees.map(\.name) + meeting.speakers.map(\.name)
        if names.contains(where: { contains($0, query) }) { return Hit(meeting: meeting, excerpt: nil) }
        let transcript = try text.transcript.get()
        if let index = transcript.lines.first(holding: needle) {
            let speaker = transcript.speakers[index]
            let name = meeting.speakers.first { $0.id == speaker }?.name ?? speaker
            return Hit(meeting: meeting, excerpt: "\(name): \(excerpt(of: transcript.lines.texts[index], at: query))")
        }
        for (part, label) in [(text.notes, "Notes"), (text.summary, "Summary")] {
            let lines = try part.get()
            if let index = lines.first(holding: needle) {
                return Hit(meeting: meeting, excerpt: "\(label): \(excerpt(of: lines.texts[index], at: query))")
            }
        }
        return nil
    }

    // A meeting's words kept in memory between searches, each part as read or the error reading it gave.
    struct Text: Sendable {
        let transcript: Result<(lines: TextSearch.Lines, speakers: [String]), any Error>
        let notes: Result<TextSearch.Lines, any Error>
        let summary: Result<TextSearch.Lines, any Error>

        init(transcript: () throws -> [TranscriptSegment], notes: () throws -> String, summary: () throws -> String) {
            self.transcript = Result { try transcript() }.map { (TextSearch.Lines($0.map(\.text)), $0.map(\.speaker)) }
            self.notes = Result { try notes() }.map(TextSearch.Lines.init(splitting:))
            self.summary = Result { try summary() }.map(TextSearch.Lines.init(splitting:))
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
