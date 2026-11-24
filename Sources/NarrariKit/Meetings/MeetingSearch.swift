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

    public static func hits(matching query: String, in store: MeetingStore, since: Date? = nil) async throws -> [Hit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetings = try await store.meetings(since: since).meetings
        guard !query.isEmpty else { return meetings.map { Hit(meeting: $0, excerpt: nil) } }
        var found: [Hit] = []
        for meeting in meetings {
            if let hit = try await hit(query, meeting, in: store) { found.append(hit) }
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

    private static func hit(_ query: String, _ meeting: Meeting, in store: MeetingStore) async throws -> Hit? {
        let names = [meeting.title] + meeting.attendees.map(\.name) + meeting.speakers.map(\.name)
        if names.contains(where: { contains($0, query) }) { return Hit(meeting: meeting, excerpt: nil) }
        let speakers = Dictionary(meeting.speakers.map { ($0.id, $0.name) }) { first, _ in first }
        if let segment = try await store.transcript(of: meeting.id).first(where: { contains($0.text, query) }) {
            return Hit(meeting: meeting, excerpt: "\(speakers[segment.speaker] ?? segment.speaker): \(excerpt(of: segment.text, at: query))")
        }
        for (document, label) in [(MeetingStore.Document.notes, "Notes"), (.summary, "Summary")] {
            let text = try await store.text(document, of: meeting.id)
            if let line = text.split(whereSeparator: \.isNewline).first(where: { contains(String($0), query) }) {
                return Hit(meeting: meeting, excerpt: "\(label): \(excerpt(of: String(line), at: query))")
            }
        }
        return nil
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
