import Foundation
import NarrariKit
import Testing

@MainActor
struct TemplatesCommandTests {
    private let settings = ThrowawaySettings()
    private let folder = TemporaryFolder()
    private let announced = Announcements()

    private func run(_ arguments: String...) async -> Command.Reply? {
        await Command(arguments: ["templates"] + arguments)?.run(in: .throwaway(in: folder, settings: settings.store, announced: announced))
    }

    private func file(_ text: String) throws -> String {
        let url = folder.url.appending(path: "\(UUID().uuidString).md")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func a_template_from_a_file_is_saved_made_the_default_and_announced() async throws {
        let reply = await run("add", "Stand-up", "--text", try file("# Blockers\nWhat holds anyone up."))

        #expect(reply?.output == "Saved Stand-up as stand-up.\n")
        #expect(await run("show", "stand-up")?.output == "Stand-up\n\n# Blockers\nWhat holds anyone up.\n")
        #expect(await run("default", "stand-up")?.status == 0)
        #expect(settings.store.value(MeetingsSettings.summaryTemplate) == "stand-up")
        #expect(await run("list")?.output.contains("stand-up *") == true)
        #expect(await run("remove", "stand-up")?.status == 0)
        #expect(settings.store.value(MeetingsSettings.summaryTemplate) == MeetingsSettings.summaryTemplate.defaultValue)
        #expect(announced.all == Array(repeating: [SummariesPageModel.changeKey, MeetingsSettings.summaryTemplate.key], count: 3).flatMap(\.self))
    }

    @Test func built_in_templates_stay_read_only_and_a_template_without_headings_is_refused() async throws {
        #expect(await run("edit", "general", "--name", "Mine")?.status == 1)
        #expect(await run("remove", "one-to-one")?.status == 1)

        let reply = await run("add", "Loose", "--text", try file("Just write something."))

        #expect(reply?.errors == "Start each heading with #, and write under it what goes there.\n")
        #expect(await run("duplicate", "general")?.output == "Saved General meeting copy as general-meeting-copy.\n")
        #expect(announced.all == [SummariesPageModel.changeKey, MeetingsSettings.summaryTemplate.key])
    }
}
