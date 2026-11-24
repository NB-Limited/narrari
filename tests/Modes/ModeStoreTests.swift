import Foundation
import NarrariKit
import Testing

struct ModeStoreTests {
    private let folder = TemporaryFolder()
    private var store: ModeStore { ModeStore(root: folder.url) }
    private var file: URL { folder.url.appending(path: "modes.json") }
    private let mail = Mode(id: "mail", name: "Mail", promptID: Prompt.email.id)
    private let chat = Mode(id: "chat", name: "Chat", promptID: Prompt.message.id, speech: .outside)

    @Test func saved_book_reads_back() throws {
        try store.edit { book in
            try book.add(mail)
            try book.add(chat)
            try book.setModes(for: "com.apple.mail", ids: ["mail", "chat"], defaultID: "chat")
            try book.setGlobalDefault("mail")
        }

        let book = try store.load()
        #expect(book.modes == [.dictation, mail, chat])
        #expect(book.modes(for: "com.apple.mail") == [mail, chat])
        #expect(book.defaultMode(for: "com.apple.mail") == chat)
        #expect(book.globalDefault == mail)
    }

    @Test func missing_file_reads_as_dictation_for_every_app() throws {
        let book = try store.load()

        #expect(book.modes == [.dictation])
        #expect(book.defaultMode(for: "com.apple.mail") == .dictation)
    }

    @Test func global_default_cannot_be_deleted() throws {
        var book = ModeBook()
        try book.add(mail)
        try book.setGlobalDefault("mail")

        #expect(throws: ModeError.isGlobalDefault) { try book.delete("mail") }
        #expect(book.mode(id: "mail") == mail)
    }

    @Test func deleting_a_mode_repairs_the_apps_that_used_it() throws {
        var book = ModeBook()
        try book.add(mail)
        try book.add(chat)
        try book.setModes(for: "com.apple.mail", ids: ["mail", "chat"], defaultID: "chat")
        try book.setModes(for: "com.tinyspeck.slackmacgap", ids: ["chat"], defaultID: "chat")

        try book.delete("chat")

        #expect(book.modes(for: "com.apple.mail") == [mail])
        #expect(book.defaultMode(for: "com.apple.mail") == mail)
        #expect(book.apps["com.tinyspeck.slackmacgap"] == nil)
        #expect(book.defaultMode(for: "com.tinyspeck.slackmacgap") == .dictation)
    }

    @Test func hand_edited_file_pointing_at_missing_modes_is_repaired_on_load() throws {
        try Data(#"""
        {"modes":[{"id":"mail","name":"Mail"}],"globalDefaultID":"gone",
         "apps":{"com.apple.mail":{"modeIDs":["gone","mail","mail"],"defaultID":"gone"}}}
        """#.utf8).write(to: file)

        let book = try store.load()

        #expect(book.globalDefault == .dictation)
        #expect(book.modes(for: "com.apple.mail").map(\.id) == ["mail"])
        #expect(book.defaultMode(for: "com.apple.mail").id == "mail")
    }
}
