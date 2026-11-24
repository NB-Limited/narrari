import NarrariKit
import Testing

struct ReplacementsTests {
    @Test func replaces_whole_phrases_only() {
        let text = Replacements.apply([Replacement(phrase: "cat", text: "dog")], to: "The cat sat in the concatenated catalogue.")

        #expect(text == "The dog sat in the concatenated catalogue.")
    }

    @Test func ignores_case_and_runs_of_spaces() {
        let text = Replacements.apply([Replacement(phrase: "nb limited", text: "NB Limited")], to: "Thanks from NB   LIMITED, see you.")

        #expect(text == "Thanks from NB Limited, see you.")
    }

    @Test func longest_phrase_wins_over_a_shorter_one_inside_it() {
        let replacements = [Replacement(phrase: "new", text: "fresh"), Replacement(phrase: "new york", text: "New York")]

        #expect(Replacements.apply(replacements, to: "new york has a new office") == "New York has a fresh office")
    }

    @Test func works_on_cyrillic_words() {
        let text = Replacements.apply([Replacement(phrase: "нб лимитед", text: "NB Limited")], to: "Поздрави от нб лимитед.")

        #expect(text == "Поздрави от NB Limited.")
    }
}
