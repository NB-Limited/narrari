import NarrariKit
import Testing

@MainActor
struct DictionaryCommandTests {
    private let settings = ThrowawaySettings()
    private let folder = TemporaryFolder()
    private let announced = Announcements()

    private func run(_ arguments: String...) async -> Command.Reply? {
        await Command(arguments: ["dictionary"] + arguments)?.run(in: .throwaway(in: folder, settings: settings.store, announced: announced))
    }

    private var list: WordList { (try? DictionaryStore(root: folder.url).load()) ?? WordList() }

    @Test func words_and_replacements_are_written_where_the_page_writes_them_and_announced() async {
        #expect(await run("add", "Narrari")?.output == "Added Narrari.\n")
        #expect(await run("replace", "nb limited", "NB Limited")?.status == 0)
        #expect(await run("replace", "NB   Limited", "NB Ltd")?.status == 0)
        #expect(await run("mark", "new line", "lineBreak")?.status == 0)

        #expect(list.words == ["Narrari"])
        #expect(list.replacements == [Replacement(phrase: "NB   Limited", text: "NB Ltd")])
        #expect(list.marks.contains(SpokenMark(phrase: "new line", mark: .lineBreak)))
        #expect(announced.all == Array(repeating: DictionaryStore.changeKey, count: 4))
        #expect(await run("list")?.output.contains("NB   Limited  NB Ltd\n") == true)
    }

    @Test func refusals_say_what_the_page_says_and_change_nothing() async {
        #expect(await run("add", "Narrari")?.status == 0)

        #expect(await run("add", "narrari")?.errors == "“narrari” is already in the list.\n")
        #expect(await run("remove", "Quokka")?.errors == "Quokka is not in the dictionary.\n")
        #expect(await run("unreplace", "nb")?.status == 1)
        #expect(await run("mark", "full", "semicolon")?.errors.hasPrefix("semicolon is not a mark. Use one of lineBreak") == true)
        #expect(await run("replace", "nb")?.status == 2)
        #expect(announced.all == [DictionaryStore.changeKey])
    }
}
