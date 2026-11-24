import Foundation
import NarrariKit
import Testing

@MainActor
struct PromptsCommandTests {
    private let settings = ThrowawaySettings()
    private let folder = TemporaryFolder()
    private let announced = Announcements()

    private func run(_ arguments: String...) async -> Command.Reply? {
        await Command(arguments: ["prompts"] + arguments)?.run(in: .throwaway(in: folder, settings: settings.store, announced: announced))
    }

    private func file(_ text: String) throws -> String {
        let url = folder.url.appending(path: "\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func a_prompt_from_a_file_is_saved_shown_and_announced() async throws {
        let reply = await run("add", "Short reply", "--text", try file("Reply in one line.\n"), "--triggers", "short reply")
        let saved = try #require(try PromptStore(root: folder.url).load().first)

        #expect(reply?.output == "Saved Short reply as \(saved.id).\n")
        #expect(saved.instruction == "Reply in one line.")
        #expect(saved.triggers == ["short reply"])
        #expect(await run("show", saved.id)?.output == "Reply in one line.\n")
        #expect(await run("edit", saved.id, "--name", "Brief")?.status == 0)
        #expect(try PromptStore(root: folder.url).load().first?.name == "Brief")
        #expect(announced.all == [PromptStore.changeKey, PromptStore.changeKey])
    }

    @Test func built_in_prompts_stay_read_only_and_a_taken_trigger_is_refused() async throws {
        #expect(await run("edit", "tidy", "--name", "Mine")?.errors == "Tidy is built in, so it can't be changed. Duplicate it to have a copy of your own.\n")
        #expect(await run("remove", "email")?.status == 1)

        let clash = await run("add", "Mail", "--text", try file("Write it as mail."), "--triggers", "Write email")

        #expect(clash?.errors == "“Write email” is already a trigger phrase of Email. Use another phrase.\n")
        #expect(await run("add", "Empty", "--text", folder.url.appending(path: "missing.txt").path)?.status == 1)
        #expect(await run("duplicate", "tidy")?.status == 0)
        #expect(try PromptStore(root: folder.url).load().map(\.name) == ["Tidy copy"])
        #expect(announced.all == [PromptStore.changeKey])
    }
}
