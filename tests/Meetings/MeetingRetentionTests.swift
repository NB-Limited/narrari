import Foundation
import NarrariKit
import Testing

struct MeetingRetentionTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let store: MeetingStore
    private let now = try! Date("2026-11-19T12:00:00Z", strategy: .iso8601)

    init() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        store = MeetingStore(root: folder.url, calendar: utc) { _ in Issue.record("nothing is trashed") }
    }

    private func recorded(at time: String, pinned: Bool = false, state: Meeting.State = .ready, isProcessed: Bool = true) async throws -> URL {
        var meeting = Meeting(
            title: time, startedAt: try Date(time, strategy: .iso8601), app: "", source: .manual, template: "general", state: state
        )
        meeting.pinned = pinned
        if isProcessed { (meeting.steps.echo, meeting.steps.transcript, meeting.steps.speakers) = (.init(.done), .init(.done), .init(.done)) }
        let url = try await store.create(meeting, appName: "")
        try await store.write("Agreed on the budget.", to: .summary, of: meeting.id)
        for name in ["mic.caf", "system.caf"] { try Data("caff".utf8).write(to: url.appending(path: name)) }
        return url
    }

    private func files(in url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    @Test func audio_of_an_unpinned_meeting_past_the_limit_goes_and_its_text_stays() async throws {
        let eightDays = try await recorded(at: "2026-11-11T23:59:59Z")
        let sevenDays = try await recorded(at: "2026-11-12T00:00:01Z")
        let pinned = try await recorded(at: "2026-11-01T10:00:00Z", pinned: true)
        let recording = try await recorded(at: "2026-11-01T11:00:00Z", state: .recording)
        let importing = try await recorded(at: "2026-11-01T12:00:00Z", state: .importing)
        let untranscribed = try await recorded(at: "2026-11-01T13:00:00Z", isProcessed: false)

        try await MeetingRetention.run(on: store, settings: settings.store, now: now)

        #expect(try files(in: eightDays) == ["meeting.json", "summary.md"])
        for kept in [sevenDays, pinned, recording, importing, untranscribed] {
            #expect(try files(in: kept) == ["meeting.json", "summary.md", "mic.caf", "system.caf"])
        }
    }

    @Test func meeting_audio_follows_its_own_setting_and_zero_days_keeps_it_forever() async throws {
        settings.store.set(1, for: HistorySettings.retentionDays)
        settings.store.set(0, for: MeetingsSettings.audioRetentionDays)
        let lastYear = try await recorded(at: "2025-10-01T08:00:00Z")

        try await MeetingRetention.run(on: store, settings: settings.store, now: now)

        #expect(try files(in: lastYear) == ["meeting.json", "summary.md", "mic.caf", "system.caf"])
    }
}
