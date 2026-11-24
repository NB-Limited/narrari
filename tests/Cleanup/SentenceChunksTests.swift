import NarrariKit
import Testing

struct SentenceChunksTests {
    private static let five = "One two three four five."

    @Test(arguments: [
        "  Hi Anna.  The build is green.\n\nShip it on Friday?  Thanks!  ",
        "Изпрати фактурата на Мария до петък. Благодаря! Ще се видим утре.",
        "会議は金曜日です。資料を送ってください。",
        "",
        " \n\t \n"
    ])
    func joining_the_pieces_rebuilds_the_text_exactly(text: String) {
        let chunks = SentenceChunks(text, maxWords: 3)

        #expect(chunks.joined(chunks.pieces) == text)
        #expect(chunks.pieces.allSatisfy { !$0.isEmpty && !$0.contains("\n") && $0.first?.isWhitespace == false })
    }

    @Test func sentences_are_grouped_up_to_the_limit_and_a_longer_one_stays_whole() {
        let long = "This sentence has far more than ten words in it and still stays whole."
        let text = [Self.five, Self.five, Self.five, long, Self.five].joined(separator: " ")

        let chunks = SentenceChunks(text, maxWords: 10)

        #expect(chunks.pieces == [Self.five + " " + Self.five, Self.five, long, Self.five])
    }

    @Test func white_space_alone_gives_no_pieces() {
        #expect(SentenceChunks("", maxWords: 40).pieces.isEmpty)
        #expect(SentenceChunks(" \n ", maxWords: 40).pieces.isEmpty)
    }

    @Test func non_latin_sentences_are_split_and_counted_by_their_words() {
        let text = "Изпрати фактурата на Мария. Благодаря ти много. Ще се видим утре."

        let chunks = SentenceChunks(text, maxWords: 4)

        #expect(chunks.pieces == ["Изпрати фактурата на Мария.", "Благодаря ти много.", "Ще се видим утре."])
    }

    @Test func a_reply_laid_out_in_lines_gets_lines_of_its_own() {
        let chunks = SentenceChunks("Buy these. Milk and eggs. Then call Anna.", maxWords: 3)

        let joined = chunks.joined(["Buy these.", "- Milk\n- Eggs", "Then call Anna."])

        #expect(chunks.pieces == ["Buy these.", "Milk and eggs.", "Then call Anna."])
        #expect(joined == "Buy these.\n- Milk\n- Eggs\nThen call Anna.")
    }
}
