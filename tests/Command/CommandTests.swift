import Foundation
import NarrariKit
import Testing

struct CommandTests {
    @Test func no_arguments_or_launch_flags_start_the_app() {
        #expect(Command(arguments: []) == nil)
        #expect(Command(arguments: ["-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    @Test @MainActor func unknown_command_prints_usage_and_fails() async {
        let folder = TemporaryFolder()
        let settings = ThrowawaySettings()
        let context = Command.Context.throwaway(in: folder, settings: settings.store)

        let reply = await Command(arguments: ["dictate"])?.run(in: context)

        #expect(reply?.status == 2)
        #expect(reply?.errors.contains("dictate is not a narrari command.") == true)
        #expect(reply?.errors.contains("Usage: narrari") == true)
    }

    @Test @MainActor func an_unreadable_list_says_what_the_window_says() async throws {
        let folder = TemporaryFolder()
        let settings = ThrowawaySettings()
        for name in ["History", "Meetings"] { try Data().write(to: folder.url.appending(path: name)) }
        let context = Command.Context.throwaway(in: folder, settings: settings.store)

        let meetings = await Command(arguments: ["meetings", "list"])?.run(in: context)
        let dictations = await Command(arguments: ["dictations", "list"])?.run(in: context)

        #expect(meetings?.errors == "The meetings could not be read. Try again.\n" && meetings?.status == 1)
        #expect(dictations?.errors == "The dictations could not be read. Try again.\n")
    }
}

struct SetupCommandWordTests {
    @Test(arguments: [
        ["shortcuts", "set", "meeting"], ["dictionary", "add"], ["prompts", "add", "Mine"], ["modes", "edit", "dictation"],
        ["templates", "add", "Mine", "--name", "x"], ["people", "forget", "boris"]
    ])
    func a_setup_command_used_wrongly_says_how_it_is_used(arguments: [String]) {
        guard case .mistake(let problem)? = Command(arguments: arguments) else {
            Issue.record("\(arguments) was not refused")
            return
        }

        #expect(problem.hasPrefix("\(arguments[0]) takes "))
    }
}
