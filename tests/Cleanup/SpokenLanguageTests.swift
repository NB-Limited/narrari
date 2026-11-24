import NarrariKit
import Testing

// Dictations and clean-up replies from 22-Nov-26.
struct SpokenLanguageTests {
    @Test func translation_differs_from_its_dictation() {
        #expect(SpokenLanguage.differs(
            "Please translate this into English, the meeting is at noon.",
            from: "Traduis ça en anglais s'il te plaît, la réunion est à midi."
        ))
        #expect(SpokenLanguage.differs("We spent the weekend in the mountains.", from: "Прекарахме уикенда в планината."))
    }

    // The recognizer reads this Bulgarian dictation as Ukrainian and the reply as Bulgarian.
    @Test func same_language_read_as_a_related_one_does_not_differ() {
        #expect(!SpokenLanguage.differs("Прати файл на Петя.", from: "Прати файла на Петя."))
        #expect(!SpokenLanguage.differs("До утре!", from: "Благодаря, до утре!"))
    }

    // One meeting line holding a sentence in each language; read whole, the recognizer calls it English.
    @Test func words_are_counted_by_the_language_of_their_sentence() {
        let line = "Добре, ще ти го изпратя днес следобед, преди срещата. Okay, and I will send the signed contract back tomorrow morning."
        #expect(SpokenLanguage.words(byLanguage: [line, "Ok."]) == ["bg": 9, "en": 11])
    }
}
