import NarrariKit
import Testing

@MainActor
struct ModesCommandTests {
    private let settings = ThrowawaySettings()
    private let folder = TemporaryFolder()
    private let announced = Announcements()

    private func run(_ arguments: String...) async -> Command.Reply? {
        await Command(arguments: ["modes"] + arguments)?.run(in: .throwaway(in: folder, settings: settings.store, announced: announced))
    }

    private var book: ModeBook { (try? ModeStore(root: folder.url).load()) ?? ModeBook() }

    @Test func a_mode_and_the_apps_that_use_it_are_saved_and_announced() async throws {
        #expect(await run("add", "Email", "--prompt", "email", "--cleanup", "on")?.status == 0)
        let email = try #require(book.modes.first { $0.name == "Email" })

        #expect(email.promptID == "email")
        #expect(await run("app", "com.apple.mail", email.id, "dictation", "--default", "dictation")?.status == 0)
        #expect(book.modes(for: "com.apple.mail").map(\.id) == [email.id, "dictation"])
        #expect(book.defaultMode(for: "com.apple.mail").id == "dictation")
        #expect(await run("default", email.id)?.status == 0)
        #expect(book.globalDefaultID == email.id)
        #expect(await run("unapp", "com.apple.mail")?.status == 0)
        #expect(book.apps.isEmpty)
        #expect(announced.all == Array(repeating: ModeStore.changeKey, count: 4))
    }

    @Test func the_page_and_mode_book_rules_refuse_the_same_here() async {
        #expect(await run("add", "dictation")?.errors == "Another mode is called dictation. Use another name.\n")
        #expect(await run("remove", "dictation")?.errors == ModesPageModel.globalDefaultReason + "\n")
        #expect(await run("add", "Notes", "--prompt", "poem")?.errors.hasPrefix("poem is not a prompt. The prompts are: tidy, email") == true)
        #expect(await run("add", "Far", "--speech", "outside")?.errors == "The outside speech service is not set up. \(ModesPageModel.outsideReason)\n")
        #expect(await run("app", "com.apple.mail", "ghost")?.errors == "No mode has the id ghost. See them with narrari modes list.\n")
        #expect(await run("app", "com.apple.mail", "dictation", "--default", "ghost")?.errors == "--default must be one of the modes given.\n")
        #expect(book == ModeBook())
        #expect(announced.all.isEmpty)
    }
}
