import Foundation
import NarrariKit
import Testing

@MainActor
struct DictionaryPageModelTests {
    private let folder = TemporaryFolder()
    private let status = ModelStatus()
    private let settings = ThrowawaySettings()

    private func page() -> DictionaryPageModel {
        let page = DictionaryPageModel(
            store: DictionaryStore(root: folder.url), settings: settings.mirror, listenerStatus: status, models: ModelStore(root: folder.url)
        )
        page.appear()
        return page
    }

    // A row is edited by its place in the list, so the list waits for the editor to close before it shows a change.
    @Test(.timeLimit(.minutes(1))) func a_list_changed_elsewhere_shows_but_waits_for_the_row_being_edited() async throws {
        let page = page()
        for (phrase, text) in [("en bee", "NB"), ("narr", "Narrari")] {
            page.newPhrase = phrase
            page.newText = text
            page.addReplacement()
        }
        page.startEditing(.replacement(1))
        page.editText = "Narrari app"
        let other = self.page()

        try DictionaryStore(root: folder.url).edit { $0.replacements.insert(Replacement(phrase: "kay", text: "K"), at: 0) }
        await until { other.list.replacements.count == 3 }
        #expect(page.list.replacements.count == 2)
        page.commitEditing()

        #expect(page.list.replacements.map(\.text) == ["K", "NB", "Narrari app"])
        await until { other.list.replacements.map(\.text) == ["K", "NB", "Narrari app"] }
    }

    @Test func phrase_that_already_has_a_replacement_is_refused() throws {
        let page = page()
        page.newPhrase = "nb limited"
        page.newText = "NB Limited"
        page.addReplacement()

        page.newPhrase = "NB   Limited"
        page.newText = "NB Ltd"
        page.addReplacement()

        #expect(page.replacementError == "“NB   Limited” already has a replacement. Edit that one instead.")
        #expect(try DictionaryStore(root: folder.url).load().replacements == [Replacement(phrase: "nb limited", text: "NB Limited")])
    }

    @Test func spoken_mark_is_added_and_edited_and_a_phrase_writes_one_mark_only() throws {
        let page = page()
        page.writesSpokenMarks = true
        page.newMarkPhrase = "nov red"
        page.addMark()
        let index = try #require(page.list.marks.firstIndex { $0.phrase == "nov red" })

        page.startEditing(.mark(index))
        page.editMark = .paragraphBreak
        page.commitEditing()
        page.newMarkPhrase = "NOV  red"
        page.addMark()

        #expect(page.markError == "“NOV  red” already writes a mark. Edit that one instead.")
        #expect(try DictionaryStore(root: folder.url).load().marks == SpokenMark.defaults + [SpokenMark(phrase: "nov red", mark: .paragraphBreak)])
        #expect(settings.store.value(DictionarySettings.writesSpokenMarks))
    }

    @Test func adding_a_word_never_writes_over_an_unreadable_file() throws {
        let file = folder.url.appending(path: "dictionary.json")
        let unreadable = Data(#"{"words":["Narrari","Baburov"],"replacements":[{"phrase":"nb"#.utf8)
        try unreadable.write(to: file)
        let page = page()
        #expect(page.file.isUnreadable)

        page.newWord = "Fontys"
        page.addWord()
        page.retryListening()

        let after = try Data(contentsOf: file)
        #expect(after == unreadable)
    }

    @Test func status_says_how_far_along_and_nothing_once_ready() async throws {
        let page = page()
        #expect(page.listeningLine == "The first word downloads about 100 MB.")
        page.newWord = "Baburov"
        page.addWord()

        status.report(.preparing(fraction: 0.4, isDownloading: true))
        await until { page.listening == .gettingReady(0.4) }
        #expect(page.listeningLine == "Getting ready, 40%")

        status.report(.ready)
        await until { page.listening == .quiet }
        #expect(page.listeningLine == nil)
    }
}
