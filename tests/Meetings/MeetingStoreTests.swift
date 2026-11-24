import Foundation
import NarrariKit
import Testing

struct MeetingStoreTests {
    private let folder = TemporaryFolder()
    private let store: MeetingStore
    private let morning = try! Date("2026-11-19T09:30:00Z", strategy: .iso8601)

    init() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let trashFolder = folder.url.appending(path: "Trash")
        store = MeetingStore(root: folder.url.appending(path: "meetings"), calendar: utc) { url in
            try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trashFolder.appending(path: url.lastPathComponent))
        }
    }

    private func meeting(_ title: String, source: Meeting.Source = .call, state: Meeting.State = .ready, at start: Date? = nil) -> Meeting {
        Meeting(title: title, startedAt: start ?? morning, app: "us.zoom.xos", source: source, template: "general", state: state)
    }

    private func path(_ url: URL) -> String {
        String(url.path.dropFirst(store.root.path.count + 1))
    }

    private func names(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func meeting_lands_in_its_apps_folder_under_a_safe_name_and_a_clash_gets_2() async throws {
        let first = try await store.create(meeting("Q4 plan: Acme/Beta <draft>?"), appName: "Zoom")
        let second = try await store.create(meeting("Q4 plan: Acme/Beta <draft>?"), appName: "Zoom")
        let unnamedApp = try await store.create(meeting("../../Library"), appName: "")
        let imported = try await store.create(meeting(String(repeating: "Ж", count: 100), source: .import), appName: "Zoom")

        #expect(path(first) == "Zoom/2026-11-19 0930 Q4 plan AcmeBeta draft")
        #expect(path(second) == "Zoom/2026-11-19 0930 Q4 plan AcmeBeta draft 2")
        #expect(path(unnamedApp) == "Recordings/2026-11-19 0930 Library")
        #expect(path(imported) == "Imported/2026-11-19 0930 " + String(repeating: "Ж", count: 80))
        #expect(try permissions(first) == 0o700)
        #expect(try permissions(first.appending(path: "meeting.json")) == 0o600)
        #expect(try await store.meetings().meetings.map(\.title).contains("Q4 plan: Acme/Beta <draft>?"))
    }

    @Test func title_given_while_recording_renames_the_folder_only_when_the_meeting_stops() async throws {
        var recording = meeting("", state: .recording)
        try await store.create(recording, appName: "Zoom")

        recording.title = "Weekly sync"
        try await store.save(recording)
        #expect(try names(in: store.root.appending(path: "Zoom")) == ["2026-11-19 0930"])

        recording.state = .ready
        recording.durationMs = 1_800_000
        try await store.save(recording)
        #expect(try names(in: store.root.appending(path: "Zoom")) == ["2026-11-19 0930 Weekly sync"])
        #expect(try await store.meetings().meetings == [recording])

        recording.title = "Weekly Sync"
        try await store.save(recording)
        #expect(try names(in: store.root.appending(path: "Zoom")) == ["2026-11-19 0930 Weekly sync"])
        #expect(try await store.meetings().meetings.map(\.title) == ["Weekly Sync"])
    }

    @Test func rewrite_keeps_keys_a_later_version_added() async throws {
        var saved = meeting("Standup")
        let url = try await store.create(saved, appName: "Zoom").appending(path: "meeting.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["mood"] = ["calm": true, "score": 3]
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        saved.pinned = true
        try await store.save(saved)

        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(written["v"] as? Int == 1)
        #expect(written["pinned"] as? Bool == true)
        #expect(written["mood"] as? [String: AnyHashable] == ["calm": true, "score": 3])
    }

    @Test func attendees_written_as_plain_names_read_as_calendar_names() async throws {
        let saved = meeting("Standup")
        let url = try await store.create(saved, appName: "Zoom").appending(path: "meeting.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["attendees"] = ["Ana Petrova"]
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        #expect(try await store.meeting(saved.id).attendees == [.init(name: "Ana Petrova", source: .calendar)])
    }

    @Test func a_silent_call_kept_before_its_reason_was_reads_as_other_peoples_sound_not_recorded() async throws {
        let saved = meeting("Standup")
        let url = try await store.create(saved, appName: "Zoom").appending(path: "meeting.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        ["systemSound", "microphoneLostPercent", "systemLostPercent"].forEach { json[$0] = nil }
        json["othersNotRecorded"] = true
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let read = try await store.meeting(saved.id)
        #expect(read.systemSound == .unheard && read.systemLostPercent == 0)
        #expect(read.soundNotes == ["Other people's sound was not recorded."])
    }

    @Test func folder_without_a_readable_meeting_json_is_listed_apart_and_left_as_it_is() async throws {
        let broken = store.root.appending(path: "Zoom/2026-11-18 1000 Broken")
        let future = store.root.appending(path: "Zoom/2026-11-18 1100 Future")
        for (folder, json) in [(broken, "{not json"), (future, #"{"v":2,"state":"recording"}"#)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: folder.appending(path: "meeting.json"))
            try Data("caff".utf8).write(to: folder.appending(path: "mic.caf"))
        }
        try await store.create(meeting("Fine"), appName: "Zoom")

        try await store.recover()

        let listing = try await store.meetings()
        #expect(listing.meetings.map(\.title) == ["Fine"])
        #expect(listing.unreadable.map(\.lastPathComponent) == ["2026-11-18 1000 Broken", "2026-11-18 1100 Future"])
        #expect(try String(contentsOf: future.appending(path: "meeting.json"), encoding: .utf8) == #"{"v":2,"state":"recording"}"#)
        #expect(try names(in: future) == ["meeting.json", "mic.caf"])
    }

    @Test func meeting_cut_off_while_recording_comes_back_recovered_under_its_title() async throws {
        var cutOff = meeting("", state: .recording)
        try await store.create(cutOff, appName: "Zoom")
        cutOff.title = "Client call"
        try await store.save(cutOff)

        try await store.recover()

        #expect(try await store.meetings().meetings.map(\.state) == [.recovered])
        #expect(try names(in: store.root.appending(path: "Zoom")) == ["2026-11-19 0930 Client call"])
    }

    @Test func an_import_cut_off_by_a_quit_is_moved_to_the_trash_at_launch() async throws {
        try await store.create(meeting("Kickoff", source: .import, state: .importing), appName: "")

        try await store.recover()

        #expect(try await store.meetings().meetings.isEmpty)
        #expect(try names(in: folder.url.appending(path: "Trash")).count == 1)
    }

    // The writer is still open, as a crash leaves it: what reached the disk counts.
    @Test func meeting_cut_off_while_recording_takes_its_length_from_the_track_written_so_far() async throws {
        let cutOff = meeting("Client call", state: .recording)
        let folder = try await store.create(cutOff, appName: "Zoom")
        let writer = try TrackWriter(writingTo: folder.appending(path: "mic.caf"), sourceRate: SpeechAudio.sampleRate)
        let second = [Float](repeating: 0.1, count: Int(SpeechAudio.sampleRate))
        for index in 0..<3 { second.withUnsafeBufferPointer { writer.append($0, at: Double(index)) } }

        try await store.recover()

        withExtendedLifetime(writer) {}
        #expect(try await store.meeting(cutOff.id).durationMs == 3000)
    }

    @Test func listing_is_newest_first_and_since_leaves_out_older_meetings() async throws {
        let older = meeting("Older", at: morning.addingTimeInterval(-86_400))
        let newer = meeting("Newer", at: morning.addingTimeInterval(3_600))
        for item in [older, meeting("Middle"), newer] { try await store.create(item, appName: "Zoom") }

        #expect(try await store.meetings().meetings.map(\.title) == ["Newer", "Middle", "Older"])
        #expect(try await store.meetings(since: morning).meetings.map(\.title) == ["Newer", "Middle"])
    }

    @Test func transcript_md_is_written_from_transcript_json_and_follows_a_speaker_rename() async throws {
        var saved = meeting("Review")
        saved.speakers = [.init(id: "owner", name: "Nick"), .init(id: "S2", name: "Speaker 2")]
        let url = try await store.create(saved, appName: "Zoom")
        let segments = [
            TranscriptSegment(start: 3.2, end: 5, speaker: "owner", text: "Shall we start?", track: .mic),
            TranscriptSegment(start: 3_725, end: 3_727, speaker: "S2", text: "Yes.", track: .system)
        ]

        try await store.write(segments, of: saved.id)
        saved.speakers[1].name = "Anna"
        try await store.save(saved)

        #expect(try await store.transcript(of: saved.id) == segments)
        #expect(try String(contentsOf: url.appending(path: "transcript.md"), encoding: .utf8) == """
            [00:00:03] Nick: Shall we start?

            [01:02:05] Anna: Yes.

            """)
        #expect(try permissions(url.appending(path: "transcript.json")) == 0o600)
        #expect(try permissions(url.appending(path: "transcript.md")) == 0o600)
    }

    @Test func deleted_meeting_goes_to_the_trash_with_all_its_files() async throws {
        let saved = meeting("Gone")
        let url = try await store.create(saved, appName: "Zoom")
        try await store.write("Call Anna back.", to: .notes, of: saved.id)

        try await store.delete(saved.id)

        #expect(try await store.meetings().meetings.isEmpty)
        #expect(try names(in: folder.url.appending(path: "Trash/\(url.lastPathComponent)")) == ["meeting.json", "notes.md"])
        await #expect(throws: MeetingError.notFound) { try await store.text(.notes, of: saved.id) }
    }
}
