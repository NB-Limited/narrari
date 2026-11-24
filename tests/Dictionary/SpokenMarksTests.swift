import NarrariKit
import Testing

struct SpokenMarksTests {
    private static let marks = SpokenMark.defaults + [
        SpokenMark(phrase: "comma", mark: .comma),
        SpokenMark(phrase: "question mark", mark: .questionMark),
        SpokenMark(phrase: "colon", mark: .colon),
        SpokenMark(phrase: "нов абзац", mark: .paragraphBreak)
    ]

    // Transcripts as the speech models wrote them in the 20-Nov-26 measurement, and what the user meant.
    @Test(arguments: [
        ("Hi team new line the build is green.", "Hi team\nThe build is green."),
        ("Hi team, new line, the build is green.", "Hi team\nThe build is green."),
        ("Hi team. New line. The build is green.", "Hi team\nThe build is green."),
        ("Thanks for the quick update. New line.", "Thanks for the quick update\n"),
        ("New paragraph. Here is the second part.", "\n\nHere is the second part."),
        ("We are done for today. Period. New paragraph. Next steps, colon, review it.", "We are done for today.\n\nNext steps: review it."),
        ("Sales went up in every region. Comma. And costs stayed flat. Period.", "Sales went up in every region, and costs stayed flat."),
        ("Why did it fail? Question mark.", "Why did it fail?"),
        ("Dear Anna, comma. New line. Thank you.", "Dear Anna,\nThank you."),
        ("That is great news, exclamation Mark.", "That is great news!"),
        ("Buy milk NEWLINE buy eggs", "Buy milk\nBuy eggs"),
        ("Това е планът. Нов абзац. Следва бюджетът.", "Това е планът\n\nСледва бюджетът."),
        ("A newspaper on the shelf.", "A newspaper on the shelf.")
    ])
    func writes_the_mark_and_only_the_mark_where_the_phrase_was(heard: String, written: String) {
        #expect(SpokenMarks.apply(Self.marks, to: heard).text == written)
    }

    @Test func counts_the_marks_written_and_leaves_text_without_a_phrase_alone() {
        #expect(SpokenMarks.apply(Self.marks, to: "One new line two new line three.").written == 2)
        let untouched = SpokenMarks.apply(Self.marks, to: "Nothing to see here.")
        #expect(untouched.text == "Nothing to see here." && untouched.written == 0)
    }
}
