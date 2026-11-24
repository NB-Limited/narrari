import Foundation
import NarrariKit
import Testing

@MainActor
struct HistoryPageModelTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private var meetings: MeetingStore { MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { _ in }) }

    @Test func delete_all_stops_playback_before_any_audio_goes() async throws {
        let store = HistoryStore(root: folder.url)
        let id = UUID()
        try await store.append(HistoryEntry(id: id, startedAt: Date(), audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted))
        try Data("caff".utf8).write(to: store.audioURL(for: id))
        var audioAtStop: [Bool] = []
        let page = HistoryPageModel(store: store, meetings: meetings, settings: settings.mirror, stopPlayback: {
            audioAtStop.append(FileManager.default.fileExists(atPath: store.audioURL(for: id).path))
        })

        page.requestDeleteAll()
        await page.confirmDeleteAll()

        #expect(audioAtStop == [true])
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: id).path))
    }

    @Test func a_retention_set_outside_the_choices_shows_in_order_before_keep_forever() {
        settings.store.set(45, for: HistorySettings.retentionDays)
        let page = HistoryPageModel(store: HistoryStore(root: folder.url), meetings: meetings, settings: settings.mirror)

        #expect(page.retentionOptions(.dictations) == [1, 3, 7, 14, 30, 45, 90, 0])
    }

    @Test func shortening_meeting_audio_asks_first_then_deletes_only_older_audio() async throws {
        let now = try Date("2026-11-19T12:00:00Z", strategy: .iso8601)
        let store = MeetingStore(root: folder.url.appending(path: "Meetings"), calendar: .current, trash: { _ in })
        var meeting = Meeting(title: "Weekly", startedAt: now.addingTimeInterval(-10 * 86_400), app: "", source: .manual, template: "general", state: .ready)
        (meeting.steps.echo, meeting.steps.transcript, meeting.steps.speakers) = (.init(.done), .init(.done), .init(.done))
        let url = try await store.create(meeting, appName: "")
        try await store.write("Agreed on the budget.", to: .summary, of: meeting.id)
        try Data("caff".utf8).write(to: url.appending(path: "mic.caf"))
        let page = HistoryPageModel(store: HistoryStore(root: folder.url), meetings: store, settings: settings.mirror, now: { now })

        await page.requestRetention(3, for: .meetingAudio)

        #expect(page.pendingRetentionMessage(.meetingAudio) == "Keeping 3 days deletes the audio of 1 meeting older than that now. Their text stays.")
        #expect(settings.store.value(MeetingsSettings.audioRetentionDays) == 7)
        #expect(settings.store.value(HistorySettings.retentionDays) == 7)

        await page.confirmRetention()

        #expect(settings.store.value(MeetingsSettings.audioRetentionDays) == 3)
        #expect(settings.store.value(HistorySettings.retentionDays) == 7)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: url.path)) == ["meeting.json", "summary.md"])
    }
}
