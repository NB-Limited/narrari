import NarrariKit
import Testing

struct ModeResolverTests {
    private let mail = Mode(id: "mail", name: "Mail", promptID: Prompt.email.id)
    private let chat = Mode(id: "chat", name: "Chat", promptID: Prompt.message.id)
    private var resolver = ModeResolver()
    private let book: ModeBook

    init() throws {
        var book = ModeBook()
        try book.add(mail)
        try book.add(chat)
        try book.setModes(for: "com.apple.mail", ids: [Mode.dictation.id, "mail", "chat"], defaultID: "mail")
        try book.setModes(for: "com.tinyspeck.slackmacgap", ids: ["chat"], defaultID: "chat")
        self.book = book
    }

    @Test mutating func app_uses_its_own_default() {
        #expect(resolver.resolve(for: "com.apple.mail", in: book) == mail)
    }

    @Test mutating func app_without_modes_uses_the_global_default() {
        #expect(resolver.resolve(for: "com.apple.Terminal", in: book) == .dictation)
    }

    @Test mutating func manual_switch_holds_until_the_app_changes() {
        #expect(resolver.select("chat", for: "com.apple.mail", in: book) == chat)
        #expect(resolver.resolve(for: "com.apple.mail", in: book) == chat)

        #expect(resolver.resolve(for: "com.tinyspeck.slackmacgap", in: book) == chat)
        #expect(resolver.resolve(for: "com.apple.mail", in: book) == mail)
    }

    @Test mutating func cycling_wraps_around_the_app_list() {
        let cycled = (0..<3).map { _ in resolver.cycle(for: "com.apple.mail", in: book)?.id }

        #expect(cycled == ["chat", "dictation", "mail"])
    }

    @Test mutating func app_with_one_mode_does_not_cycle() {
        #expect(resolver.cycle(for: "com.tinyspeck.slackmacgap", in: book) == nil)
        #expect(resolver.cycle(for: "com.apple.Terminal", in: book) == nil)
    }
}
