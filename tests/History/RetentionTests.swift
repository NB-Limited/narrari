import Foundation
import NarrariKit
import Testing

struct RetentionTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let store: HistoryStore
    private let meetings: MeetingStore
    private let now = try! Date("2026-11-19T12:00:00Z", strategy: .iso8601)

    init() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        store = HistoryStore(root: folder.url, calendar: utc)
        meetings = MeetingStore(root: folder.url.appending(path: "Meetings"), calendar: utc) { _ in Issue.record("nothing is trashed") }
    }

    private func dictation(at time: String) async throws -> HistoryEntry {
        let id = UUID()
        let entry = HistoryEntry(id: id, startedAt: try Date(time, strategy: .iso8601), audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted)
        try await store.append(entry)
        try Data("caff".utf8).write(to: store.audioURL(for: id))
        return entry
    }

    private func remaining() async throws -> Set<UUID> {
        Set(try await store.entries().entries.map(\.id))
    }

    private func hasAudio(_ entry: HistoryEntry) -> Bool {
        FileManager.default.fileExists(atPath: store.audioURL(for: entry.id).path)
    }

    private func meetingAudio(at time: String, state: Meeting.State) async throws -> URL {
        var meeting = Meeting(title: "", startedAt: try Date(time, strategy: .iso8601), app: "", source: .manual, template: "general", state: state)
        (meeting.steps.echo, meeting.steps.transcript, meeting.steps.speakers) = (.init(.done), .init(.done), .init(.done))
        let audio = try await meetings.create(meeting, appName: "").appending(path: "mic.caf")
        try Data("caff".utf8).write(to: audio)
        return audio
    }

    @MainActor
    @Test func dictation_and_meeting_audio_ageing_past_the_limit_while_narrari_runs_go_at_the_next_daily_run() async throws {
        settings.store.set(1, for: HistorySettings.retentionDays)
        settings.store.set(1, for: MeetingsSettings.audioRetentionDays)
        let yesterday = try await dictation(at: "2026-11-18T12:00:00Z")
        let meetingAudio = try await meetingAudio(at: "2026-11-18T13:00:00Z", state: .ready)
        let clock = TestClock()
        let day = Duration.seconds(24 * 60 * 60)
        let schedule = RetentionSchedule(
            store: store, meetings: meetings, settings: settings.store, clock: clock, now: { [now] in now.addingTimeInterval(clock.seconds) }
        )

        // The daily loop sleeps again only after a run, so its next sleeper marks that run done.
        schedule.start()
        await clock.waitForSleeper(until: TestClock.Instant(offset: day))
        #expect(try await remaining() == [yesterday.id])
        #expect(FileManager.default.fileExists(atPath: meetingAudio.path))
        clock.advance(by: day)
        await clock.waitForSleeper(until: TestClock.Instant(offset: day * 2))

        #expect(try await remaining().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: meetingAudio.path))
    }

    @Test func seven_days_keeps_the_seventh_day_and_removes_the_eighth_with_its_audio() async throws {
        let eightDays = try await dictation(at: "2026-11-11T23:59:59Z")
        let sevenDays = try await dictation(at: "2026-11-12T00:00:01Z")
        let sixDays = try await dictation(at: "2026-11-13T12:00:00Z")

        try await Retention.run(on: store, settings: settings.store, now: now)

        #expect(try await remaining() == [sevenDays.id, sixDays.id])
        #expect(!hasAudio(eightDays))
        #expect(hasAudio(sevenDays) && hasAudio(sixDays))
    }

    @Test func dictation_still_recording_survives_retention_of_the_day_it_started() async throws {
        let finished = try await dictation(at: "2026-11-11T22:00:00Z")
        let recordingID = UUID()
        let recording = HistoryEntry(
            id: recordingID, startedAt: try Date("2026-11-11T23:59:30Z", strategy: .iso8601), audioFile: HistoryEntry.audioFileName(for: recordingID)
        )
        try await store.append(recording)
        try Data("caff".utf8).write(to: store.audioURL(for: recordingID))

        try await Retention.run(on: store, settings: settings.store, now: now, keeping: [recordingID])

        #expect(try await remaining() == [recordingID])
        #expect(hasAudio(recording))
        #expect(!hasAudio(finished))
    }

    @Test func zero_days_keeps_history_forever() async throws {
        settings.store.set(0, for: HistorySettings.retentionDays)
        let lastYear = try await dictation(at: "2025-10-01T08:00:00Z")

        try await Retention.run(on: store, settings: settings.store, now: now)

        #expect(try await remaining() == [lastYear.id])
        #expect(hasAudio(lastYear))
    }

    @Test func shorter_retention_removes_more_days() async throws {
        settings.store.set(1, for: HistorySettings.retentionDays)
        let twoDays = try await dictation(at: "2026-11-17T18:00:00Z")
        let yesterday = try await dictation(at: "2026-11-18T07:00:00Z")

        try await Retention.run(on: store, settings: settings.store, now: now)

        #expect(try await remaining() == [yesterday.id])
        #expect(!hasAudio(twoDays))
    }
}
