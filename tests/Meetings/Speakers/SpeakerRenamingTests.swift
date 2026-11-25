import Foundation
import NarrariKit
import Testing

struct SpeakerRenamingTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let store: MeetingStore
    private let memory: VoiceMemory
    private let renaming: SpeakerRenaming

    init() {
        store = MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { _ in })
        memory = VoiceMemory(folder: folder.url)
        renaming = SpeakerRenaming(store: store, memory: memory, settings: settings.store)
    }

    private func meeting(speaker: String, print: [Float]) async throws -> UUID {
        var meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        meeting.speakers = [Meeting.Speaker(id: speaker, name: "Speaker 2")]
        try await store.create(meeting, appName: "Zoom")
        try await store.write(voices: [speaker: print], of: meeting.id)
        return meeting.id
    }

    private func boris() async throws -> VoiceMemory.Person {
        try #require(try await memory.people().first { $0.name == "Boris Ivanov" })
    }

    @Test func a_new_name_makes_a_person_renaming_teaches_them_and_not_this_person_takes_it_back() async throws {
        let first = try await meeting(speaker: "speaker-2", print: voicePrint(1))
        let second = try await meeting(speaker: "speaker-2", print: voicePrint(1, distance: 0.1))

        try await renaming.rename("speaker-2", in: first, to: "Boris Ivanov")
        try await renaming.rename("speaker-2", in: second, toPerson: try await boris().id)
        #expect(try await boris().prints.map(\.meeting) == [first, second])
        try await renaming.notThisPerson("speaker-2", in: second)

        #expect(try await boris().prints.map(\.meeting) == [first])
        #expect(try await store.meeting(first).speakers == [
            Meeting.Speaker(id: "speaker-2", name: "Boris Ivanov", personId: try await boris().id, isNamedByUser: true)
        ])
        #expect(try await store.meeting(second).speakers == [Meeting.Speaker(id: "speaker-2", name: "Speaker 2")])
    }

    @Test func a_person_keeps_the_prints_of_their_last_8_meetings() async throws {
        var meetings: [UUID] = []
        for _ in 0..<9 { meetings.append(try await meeting(speaker: "speaker-2", print: voicePrint(1))) }

        for id in meetings { try await renaming.rename("speaker-2", in: id, to: "Boris Ivanov") }

        #expect(try await boris().prints.map(\.meeting) == Array(meetings.dropFirst()))
    }

    @Test func forgetting_a_person_removes_every_print_and_leaves_their_name_in_past_meetings_as_text() async throws {
        let id = try await meeting(speaker: "speaker-2", print: voicePrint(1))
        try await renaming.rename("speaker-2", in: id, to: "Boris Ivanov")

        try await renaming.forget(try await boris().id)

        #expect(try await memory.people().isEmpty)
        #expect(try await store.voices(of: id).isEmpty)
        #expect(try await store.meeting(id).speakers == [Meeting.Speaker(id: "speaker-2", name: "Boris Ivanov", isNamedByUser: true)])
    }

    @Test func merging_gives_a_speakers_lines_to_the_other_and_drops_their_voice() async throws {
        var meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        meeting.speakers = [Meeting.Speaker(id: "speaker-2", name: "Maria Petrova"), Meeting.Speaker(id: "speaker-3", name: "Speaker 3")]
        try await store.create(meeting, appName: "Zoom")
        try await store.write(voices: ["speaker-2": voicePrint(1), "speaker-3": voicePrint(2)], of: meeting.id)
        try await store.write([
            TranscriptSegment(start: 0, end: 1, speaker: "speaker-2", text: "Hello.", track: .system),
            TranscriptSegment(start: 2, end: 3, speaker: "speaker-3", text: "Hi.", track: .system)
        ], of: meeting.id)

        try await renaming.merge("speaker-3", into: "speaker-2", in: meeting.id)

        #expect(try await store.meeting(meeting.id).speakers.map(\.id) == ["speaker-2"])
        #expect(try await store.transcript(of: meeting.id).map(\.speaker) == ["speaker-2", "speaker-2"])
        #expect(try await store.voices(of: meeting.id).keys.sorted() == ["speaker-2"])
    }

    @Test func merging_into_you_gives_you_their_lines_and_teaches_your_voice_nothing() async throws {
        let owner = #"[{"id":"\#(UUID().uuidString)","name":"Mila Novak","isOwner":true,"prints":[{"meeting":"\#(UUID().uuidString)","values":[1,0]}]}]"#
        try Data(owner.utf8).write(to: folder.url.appending(path: "people.json"))
        let remembered = try await memory.people()
        var meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        meeting.speakers = [Meeting.Speaker(id: "owner", name: "Mila Novak", personId: remembered[0].id), Meeting.Speaker(id: "speaker-2", name: "Speaker 2")]
        try await store.create(meeting, appName: "Zoom")
        try await store.write(voices: ["owner": voicePrint(1), "speaker-2": voicePrint(2)], of: meeting.id)
        try await store.write([
            TranscriptSegment(start: 0, end: 1, speaker: "owner", text: "Hello.", track: .mic),
            TranscriptSegment(start: 2, end: 3, speaker: "speaker-2", text: "Hi.", track: .system)
        ], of: meeting.id)

        try await renaming.merge("speaker-2", into: "owner", in: meeting.id)

        #expect(try await store.meeting(meeting.id).speakers.map(\.id) == ["owner"])
        #expect(try await store.transcript(of: meeting.id).map(\.speaker) == ["owner", "owner"])
        #expect(try await store.voices(of: meeting.id) == ["owner": voicePrint(1)])
        #expect(try await memory.people() == remembered)
        #expect(try await store.meeting(meeting.id).speakerEdits == [Meeting.SpeakerEdit(speaker: "speaker-2", change: .merged(into: "owner"))])
    }
}
