import Foundation
import NarrariKit
import Testing

@MainActor
struct PeoplePageModelTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    @Test func forgetting_a_person_takes_them_off_the_list_and_out_of_voice_memory() async throws {
        let store = MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { _ in })
        let memory = VoiceMemory(folder: folder.url)
        let renaming = SpeakerRenaming(store: store, memory: memory, settings: settings.store)
        var meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        meeting.speakers = [Meeting.Speaker(id: "speaker-2", name: "Speaker 2")]
        try await store.create(meeting, appName: "Zoom")
        try await store.write(voices: ["speaker-2": voicePrint(1)], of: meeting.id)
        try await renaming.rename("speaker-2", in: meeting.id, to: "Boris Ivanov")
        let page = PeoplePageModel(settings: settings.mirror, memory: memory, renaming: renaming)
        await page.appear()
        let boris = try #require(page.people.first)

        await page.forget(boris.id)

        #expect(page.people.isEmpty)
        #expect(try await memory.people().isEmpty)
        #expect(try await store.meeting(meeting.id).speakers.first?.name == "Boris Ivanov")
    }
}
