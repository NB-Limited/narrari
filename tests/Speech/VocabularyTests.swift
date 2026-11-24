import NarrariKit
import Testing

struct VocabularyTests {
    @Test func a_boosted_spelling_takes_the_time_of_the_words_it_replaces_and_the_rest_keep_theirs() {
        let heard = [("ask", 0.0, 0.3), ("anna", 0.4, 0.7), ("petrov", 0.7, 1.0), ("a", 1.0, 1.1), ("today", 1.3, 1.7)]
            .map { Transcript.Word(text: $0, start: $1, end: $2) }

        let words = Transcript.Word.respelled(heard, as: "ask Ana Petrova today")

        #expect(words == [
            .init(text: "ask", start: 0, end: 0.3), .init(text: "Ana", start: 0.4, end: 0.75),
            .init(text: "Petrova", start: 0.75, end: 1.1), .init(text: "today", start: 1.3, end: 1.7)
        ])
    }
}
