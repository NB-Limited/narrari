import Foundation
import NarrariKit
import Testing

struct DictionaryStoreTests {
    private let folder = TemporaryFolder()
    private var store: DictionaryStore { DictionaryStore(root: folder.url) }
    private var file: URL { folder.url.appending(path: "dictionary.json") }

    @Test func saved_list_reads_back() throws {
        let list = WordList(words: ["Narrari", "Бабуров"], replacements: [Replacement(phrase: "nb limited", text: "NB Limited")])

        try store.edit { $0 = list }

        #expect(try store.load() == list)
    }

    @Test func missing_file_reads_as_an_empty_list() throws {
        #expect(try store.load() == WordList())
    }

    @Test func file_without_replacements_reads_its_words() throws {
        try Data(#"{"words":["Narrari"]}"#.utf8).write(to: file)

        #expect(try store.load() == WordList(words: ["Narrari"]))
    }

    @Test func file_from_before_spoken_marks_gets_the_default_marks_and_an_emptied_list_stays_empty() throws {
        try Data(#"{"words":["Narrari"]}"#.utf8).write(to: file)
        #expect(try store.load().marks == SpokenMark.defaults)

        try store.edit { $0.marks = [] }

        #expect(try store.load().marks.isEmpty)
    }

    @Test func unreadable_list_reads_as_empty_where_the_words_are_optional() throws {
        try Data(#"{"words":["Narrari""#.utf8).write(to: file)

        #expect(store.loadOrEmpty("dictionary-load") == WordList())
    }
}
