import Foundation
import NarrariKit
import Testing

struct MeetingSearchTests {
    private let folder = TemporaryFolder()
    private let store: MeetingStore
    private let morning = try! Date("2026-11-19T09:30:00Z", strategy: .iso8601)

    init() {
        store = MeetingStore(root: folder.url) { _ in Issue.record("nothing is trashed") }
    }

    private func saved(_ title: String, hoursAgo: Double = 0, change: (inout Meeting) -> Void = { _ in }) async throws -> Meeting {
        var meeting = Meeting(
            title: title, startedAt: morning.addingTimeInterval(-hoursAgo * 3_600), app: "", source: .manual, template: "general", state: .ready
        )
        change(&meeting)
        try await store.create(meeting, appName: "")
        return meeting
    }

    private func titles(matching query: String, since: Date? = nil) async throws -> [String] {
        try await MeetingSearch.meetings(matching: query, in: store, since: since).map(\.title)
    }

    @Test func every_text_of_a_meeting_is_searched_ignoring_case_and_accents() async throws {
        _ = try await saved("Résumé review", hoursAgo: 1)
        _ = try await saved("Kick-off", hoursAgo: 2) { $0.attendees = [.init(name: "Zoë Ångström", source: .callWindow)] }
        _ = try await saved("Sync", hoursAgo: 3) { $0.speakers = [.init(id: "S2", name: "Šimić")] }
        let notes = try await saved("Notes", hoursAgo: 4)
        try await store.write("Send the quote to Müller.", to: .notes, of: notes.id)
        let summary = try await saved("Summary", hoursAgo: 5)
        try await store.write("Budget approved for Q1.", to: .summary, of: summary.id)
        let transcript = try await saved("Transcript", hoursAgo: 6)
        try await store.write([TranscriptSegment(start: 0, end: 2, speaker: "S2", text: "Ça va, Ünal?", track: .system)], of: transcript.id)

        #expect(try await titles(matching: "RESUME") == ["Résumé review"])
        #expect(try await titles(matching: "zoe angstrom") == ["Kick-off"])
        #expect(try await titles(matching: "simic") == ["Sync"])
        #expect(try await titles(matching: "muller") == ["Notes"])
        #expect(try await titles(matching: "budget") == ["Summary"])
        #expect(try await titles(matching: "ca va, unal") == ["Transcript"])
        #expect(try await titles(matching: "invoice").isEmpty)
    }

    @Test func search_finds_what_reading_every_file_again_finds() async throws {
        let words = [
            "Zoë", "ZOE", "Ångström", "straße", "STRASSE", "ﬁnance", "Ünal", "Çağrı", "İstanbul", "ısık", "Привет", "ПРИВЕТ", "йога",
            "ёлка", "Ελλάδα", "日本語", "😀", "cafe\u{301}", "café", "naïve", "œuvre", "Œ", "ǅemal", "budget", "Rotterdam", "hub", "Q1"
        ]
        var seed: UInt64 = 7
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33) % bound
        }
        func sentence() -> String { (0..<(3 + next(10))).map { _ in words[next(words.count)] }.joined(separator: " ") }
        for index in 0..<12 {
            let meeting = try await saved(index % 4 == 0 ? words[next(words.count)] : "Meeting \(index)", hoursAgo: Double(index)) {
                $0.speakers = [.init(id: "S1", name: index % 3 == 0 ? "Şimşek" : "Anna"), .init(id: "S2", name: "Bob")]
            }
            let segments = (0..<next(30)).map { line in
                TranscriptSegment(start: Double(line), end: Double(line) + 1, speaker: ["S1", "S2", "owner"][next(3)], text: sentence(), track: .mic)
            }
            try await store.write(segments, of: meeting.id)
            if index % 2 == 0 { try await store.write((0..<4).map { _ in sentence() }.joined(separator: "\r\n\n"), to: .notes, of: meeting.id) }
            if index % 3 != 2 { try await store.write("# Summary\n" + sentence() + "\n" + sentence(), to: .summary, of: meeting.id) }
        }
        let queries = words + words.map { $0.uppercased() } + words.map { $0.lowercased() } + [
            "zoe", "angstrom", "strasse", "finance", "unal", "cagri", "istanbul", "isik", "привет", "иога", "елка", "ελλαδα", "cafe",
            "naive", "oeuvre", "dzemal", "ss", "i", "I", "e", "\u{301}", "budget rotterdam", "hub Q1", "anna", "simsek", "zzz", " hub "
        ]

        for query in queries {
            let found = try await MeetingSearch.hits(matching: query, in: store).map { [$0.meeting.id.uuidString, $0.excerpt ?? ""] }
            #expect(found == (try await readingEveryFile(query)), "\(query)")
        }
    }

    @Test func a_file_changed_after_a_search_is_searched_as_it_is_now() async throws {
        let meeting = try await saved("Weekly")
        try await store.write("Ship the hub plan.", to: .notes, of: meeting.id)
        #expect(try await titles(matching: "hub") == ["Weekly"])

        try Data("Call the bank.".utf8).write(to: try await store.folder(of: meeting.id).appending(path: "notes.md"))
        let other = MeetingStore(root: folder.url) { _ in }
        try await other.write([TranscriptSegment(start: 0, end: 1, speaker: "owner", text: "The invoice is late.", track: .mic)], of: meeting.id)

        #expect(try await titles(matching: "hub").isEmpty)
        #expect(try await titles(matching: "bank") == ["Weekly"])
        #expect(try await titles(matching: "invoice") == ["Weekly"])
    }

    @Test func a_cancelled_search_stops() async throws {
        _ = try await saved("Weekly")
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingSearch.hits(matching: "weekly", in: store)
        }

        await #expect(throws: CancellationError.self) { try await search.value }
    }

    // The search as it was before the words were kept in memory: every file read again, every line compared.
    private func readingEveryFile(_ query: String) async throws -> [[String]] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [[String]] = []
        for meeting in try await store.meetings().meetings {
            let hit = { (excerpt: String?) in found.append([meeting.id.uuidString, excerpt ?? ""]) }
            let names = [meeting.title] + meeting.attendees.map(\.name) + meeting.speakers.map(\.name)
            if names.contains(where: { MeetingSearch.contains($0, query) }) {
                hit(nil)
                continue
            }
            let speakers = Dictionary(meeting.speakers.map { ($0.id, $0.name) }) { first, _ in first }
            if let segment = try await store.transcript(of: meeting.id).first(where: { MeetingSearch.contains($0.text, query) }) {
                hit("\(speakers[segment.speaker] ?? segment.speaker): \(excerpt(of: segment.text, at: query))")
                continue
            }
            for (document, label) in [(MeetingStore.Document.notes, "Notes"), (.summary, "Summary")] {
                let text = try await store.text(document, of: meeting.id)
                if let line = text.split(whereSeparator: \.isNewline).first(where: { MeetingSearch.contains(String($0), query) }) {
                    hit("\(label): \(excerpt(of: String(line), at: query))")
                    break
                }
            }
        }
        return found
    }

    private func excerpt(of text: String, at query: String) -> String {
        guard let hit = MeetingSearch.range(of: query, in: text), text.distance(from: text.startIndex, to: hit.lowerBound) > 40 else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        let before = text[..<hit.lowerBound].split(separator: " ", omittingEmptySubsequences: false)
        return "…" + before.suffix(5).joined(separator: " ") + text[hit.lowerBound...]
    }

    @Test func blank_query_lists_every_meeting_since_the_date_newest_first() async throws {
        _ = try await saved("Last week", hoursAgo: 24 * 7)
        _ = try await saved("Yesterday", hoursAgo: 24)
        _ = try await saved("Today")

        #expect(try await titles(matching: "  ", since: morning.addingTimeInterval(-48 * 3_600)) == ["Today", "Yesterday"])
    }
}
