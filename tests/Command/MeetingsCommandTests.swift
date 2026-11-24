import Foundation
import NarrariKit
import Testing

@MainActor
struct MeetingsCommandTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let meetings: MeetingStore
    private let context: Command.Context
    private let morning = try! Date("2026-11-19T09:30:00Z", strategy: .iso8601)

    init() {
        meetings = MeetingStore(root: folder.url.appending(path: "Meetings")) { _ in Issue.record("nothing is trashed") }
        context = .throwaway(in: folder, settings: settings.store, meetings: meetings)
    }

    private func saved(_ title: String, daysAgo: Double) async throws -> Meeting {
        var meeting = Meeting(
            title: title, startedAt: morning.addingTimeInterval(-daysAgo * 86_400), app: "", source: .manual, template: "general", state: .ready
        )
        meeting.speakers = [.init(id: "S1", name: "Nick"), .init(id: "S2", name: "Anna")]
        try await meetings.create(meeting, appName: "")
        return meeting
    }

    private func run(_ arguments: String...) async -> Command.Reply? {
        await Command(arguments: ["meetings"] + arguments)?.run(in: context)
    }

    @Test func list_prints_a_row_per_meeting_newest_first_and_json_on_request() async throws {
        let old = try await saved("Kick-off", daysAgo: 10)
        let new = try await saved("Weekly sync", daysAgo: 1)

        let rows = try #require(await run("list")).output.split(separator: "\n")
        let since = try #require(await run("list", "--since", "2026-11-15")).output
        let json = try #require(await run("list", "--json")).output

        #expect(rows.count == 3)
        #expect(rows[0].hasPrefix("ID"))
        #expect(rows[1].hasPrefix(new.id.uuidString) && rows[1].hasSuffix("Weekly sync"))
        #expect(rows[2].hasPrefix(old.id.uuidString) && rows[2].hasSuffix("Kick-off"))
        #expect(since.contains("Weekly sync") && !since.contains("Kick-off"))
        let listed = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(listed.compactMap { $0["id"] as? String } == [new.id.uuidString, old.id.uuidString])
    }

    @Test func show_prints_the_whole_meeting_or_one_part_and_fails_on_an_unknown_id() async throws {
        let meeting = try await saved("Weekly sync", daysAgo: 1)
        try await meetings.write("Ship on Friday.", to: .summary, of: meeting.id)
        try await meetings.write(
            [TranscriptSegment(start: 61, end: 63, speaker: "S2", text: "Friday works.", track: .system)], of: meeting.id
        )

        let whole = try #require(await run("show", meeting.id.uuidString)).output
        let transcript = try #require(await run("show", meeting.id.uuidString, "--part", "transcript")).output
        let notes = try #require(await run("show", meeting.id.uuidString, "--part", "notes")).output
        let unknown = await run("show", UUID().uuidString)

        #expect(whole.hasPrefix("# Weekly sync\n"))
        #expect(whole.contains("## Summary\n\nShip on Friday.\n"))
        #expect(whole.contains("## Transcript\n\n[00:01:01] Anna: Friday works.\n"))
        #expect(!whole.contains("## Notes"))
        #expect(transcript == "[00:01:01] Anna: Friday works.\n")
        #expect(notes == "This meeting has no notes.\n")
        #expect(unknown?.status == 1)
        #expect(await run("show", "not-an-id")?.status == 2)
    }
}
