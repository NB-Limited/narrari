import Foundation
import NarrariKit
import Testing

@MainActor
struct PeopleCommandTests {
    private let settings = ThrowawaySettings()
    private let folder = TemporaryFolder()
    private let announced = Announcements()

    private var meetings: MeetingStore { MeetingStore(root: folder.url.appending(path: "Meetings"), trash: { _ in }) }

    private func run(_ arguments: String...) async -> Command.Reply? {
        await Command(arguments: ["people"] + arguments)?.run(in: .throwaway(
            in: folder, settings: settings.store, meetings: meetings, announced: announced
        ))
    }

    private func meet(_ name: String) async throws -> UUID {
        let memory = VoiceMemory(folder: folder.url)
        var meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        meeting.speakers = [Meeting.Speaker(id: "speaker-2", name: "Speaker 2")]
        try await meetings.create(meeting, appName: "Zoom")
        try await meetings.write(voices: ["speaker-2": voicePrint(1)], of: meeting.id)
        try await SpeakerRenaming(store: meetings, memory: memory, settings: settings.store).rename("speaker-2", in: meeting.id, to: name)
        return try #require(try await memory.people().first { $0.name == name }).id
    }

    @Test func a_person_is_renamed_and_forgotten_as_on_the_people_page() async throws {
        let id = try await meet("Boris")

        #expect(await run("rename", id.uuidString, "Boris", "Ivanov")?.output == "Renamed to Boris Ivanov.\n")
        #expect(await run("list")?.output.contains("\(id.uuidString)  Boris Ivanov\n") == true)
        #expect(await run("forget", id.uuidString)?.output == "Forgot Boris Ivanov. Past meetings keep the name.\n")
        #expect(try await VoiceMemory(folder: folder.url).people().isEmpty)
        #expect(announced.all == [PeoplePageModel.changeKey, PeoplePageModel.changeKey])
    }

    @Test func an_unknown_person_or_a_missing_name_changes_nothing() async {
        let id = UUID()

        #expect(await run("rename", id.uuidString, "Boris")?.errors == "No person has the id \(id.uuidString). See them with narrari people list.\n")
        #expect(await run("rename", id.uuidString)?.status == 2)
        #expect(await run("list", "--json")?.output == "[]\n")
        #expect(announced.all.isEmpty)
    }
}
