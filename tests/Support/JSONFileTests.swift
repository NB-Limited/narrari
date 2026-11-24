import Foundation
import NarrariKit
import Testing

struct JSONFileTests {
    private let folder = TemporaryFolder()

    @Test func edit_never_writes_over_an_unreadable_file() throws {
        let file = JSONFile(folder.url.appending(path: "dictionary.json"), empty: WordList())
        try Data(#"{"words":["Narrari""#.utf8).write(to: file.url)

        #expect(throws: DecodingError.self) { try file.edit { $0.words.append("Baburov") } }
        #expect(try Data(contentsOf: file.url) == Data(#"{"words":["Narrari""#.utf8))
    }

    @Test func a_file_first_written_by_edit_is_the_owners_alone() throws {
        let file = JSONFile(folder.url.appending(path: "prompts.json"), empty: WordList())

        try file.edit { $0.words.append("Baburov") }

        #expect(try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int == 0o600)
    }
}
