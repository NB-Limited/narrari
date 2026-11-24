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

    @Test func blank_query_lists_every_meeting_since_the_date_newest_first() async throws {
        _ = try await saved("Last week", hoursAgo: 24 * 7)
        _ = try await saved("Yesterday", hoursAgo: 24)
        _ = try await saved("Today")

        #expect(try await titles(matching: "  ", since: morning.addingTimeInterval(-48 * 3_600)) == ["Today", "Yesterday"])
    }
}
