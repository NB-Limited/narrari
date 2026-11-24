import NarrariKit
import Testing

struct TextDiffTests {
    typealias Segment = TextDiff.Segment

    @Test func removed_filler_is_marked_and_the_rest_kept_as_heard() {
        let diff = TextDiff.words(from: "um so I think we ship on friday", to: "So I think we ship on Friday.")

        #expect(diff == [Segment(.removed, "um"), Segment(.kept, "so I think we ship on friday")])
    }

    @Test func changed_word_shows_as_removed_then_inserted() {
        let diff = TextDiff.words(from: "send it to marie", to: "Send it to Maria.")

        #expect(diff == [Segment(.kept, "send it to"), Segment(.removed, "marie"), Segment(.inserted, "Maria.")])
    }

    @Test(arguments: [("hello world", "Hello, world."), ("HELLO WORLD", "hello world"), ("hello  world", "hello world")])
    func case_and_punctuation_changes_keep_the_words(heard: String, final: String) {
        #expect(TextDiff.words(from: heard, to: final) == [Segment(.kept, heard.split(separator: " ").joined(separator: " "))])
    }

    @Test func repeated_word_strikes_the_second_copy() {
        let diff = TextDiff.words(from: "the the cat sat", to: "The cat sat.")

        #expect(diff == [Segment(.kept, "the"), Segment(.removed, "the"), Segment(.kept, "cat sat")])
    }

    @Test func empty_side_is_all_inserted_or_all_removed() {
        #expect(TextDiff.words(from: "", to: "").isEmpty)
        #expect(TextDiff.words(from: "", to: "Hi there.") == [Segment(.inserted, "Hi there.")])
        #expect(TextDiff.words(from: "hi there", to: "") == [Segment(.removed, "hi there")])
    }
}
