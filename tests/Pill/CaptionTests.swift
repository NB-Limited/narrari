import Foundation
import NarrariKit
import Testing

struct CaptionTests {
    @Test func a_sliding_window_is_laid_onto_the_words_heard_before_it() {
        let heard = "Hi Maria thanks for the quick reply. Thursday at ten"
        #expect(Caption.merge(heard, window: "the quick reply, Thursday at ten works for me")
            == "Hi Maria thanks for the quick reply, Thursday at ten works for me")
    }

    @Test func a_window_cut_mid_word_skips_the_fragment() {
        #expect(Caption.merge("Hi Maria thanks for the quick reply", window: "ria thanks for the quick reply and")
            == "Hi Maria thanks for the quick reply and")
    }

    @Test func a_window_that_still_covers_everything_keeps_its_revisions() {
        #expect(Caption.merge("Hi Marie thanks for", window: "Hi Maria thanks for the") == "Hi Maria thanks for the")
    }

    @Test func a_window_with_nothing_in_common_replaces_the_caption() {
        #expect(Caption.merge("one two three", window: "four five") == "four five")
    }

    @Test func a_reworded_word_changes_in_place_and_only_words_past_the_old_end_fade_in() {
        #expect(Caption.freshWords(from: "Hi Marie thanks", to: "Hi Maria thanks for") == 3..<4)
        #expect(Caption.freshWords(from: "about the launch plan.", to: "about the launch plan, I think") == 4..<6)
        #expect(Caption.freshWords(from: "We still have to be a", to: "We still need to settle.").isEmpty)
    }

    @Test func a_long_dictation_merges_its_newest_words_as_before() {
        let heard = (0..<300).map { "word\($0)" }.joined(separator: " ")
        let window = (275..<299).map { "word\($0)" }.joined(separator: " ") + " revised and more"
        #expect(Caption.merge(heard, window: window)
            == (0..<299).map { "word\($0)" }.joined(separator: " ") + " revised and more")
    }

    @Test func the_plate_keeps_its_last_lines_and_the_words_after_the_cut() {
        let heard = Self.words(0..<60)
        let cut = Caption.cut(heard, at: .none, lineStarts: [0, 10, 20, 30, 40, 50], lastWord: 59)
        #expect(cut.words == 20 && cut.lines == 2)
        #expect(Caption.tail(heard, after: cut) == Self.words(20..<60))

        let grown = Self.words(0..<58) + " w58x w59 w60 w61"
        let kept = Caption.cut(cut, from: heard, to: grown)
        #expect(kept == cut)
        #expect(Caption.freshWords(from: heard, to: grown, after: kept) == Caption.freshWords(from: heard, to: grown))
        #expect(Caption.cut(grown, at: kept, lineStarts: [20, 30, 40, 50, 60], lastWord: 61).words == 30)
    }

    @Test func a_cut_never_opens_on_a_line_with_a_hyphenated_word() {
        let heard = Self.words(0..<25) + " well-known " + Self.words(26..<60)
        let cut = Caption.cut(heard, at: .none, lineStarts: [0, 10, 20, 30, 40, 50], lastWord: 59)
        #expect(cut.words == 10 && cut.lines == 1)
    }

    @Test func a_change_before_the_cut_or_a_shrinking_merge_lays_the_whole_caption_out_again() {
        let heard = Self.words(0..<60)
        let cut = Caption.cut(heard, at: .none, lineStarts: [0, 10, 20, 30, 40, 50], lastWord: 59)
        #expect(Caption.cut(cut, from: heard, to: "W0" + heard.dropFirst(2)) == .none)
        #expect(Caption.cut(heard, at: .none, lineStarts: [0, 10, 20, 30, 40, 50], lastWord: 58) == .none)
        let shrunk = Self.words(0..<38)
        #expect(Caption.cut(shrunk, at: cut, lineStarts: [20, 30], lastWord: 37) == .none)
    }

    @Test func the_line_count_is_the_same_from_any_cut_and_a_stale_layout_counts_nothing() {
        let heard = Self.words(0..<60)
        let cut = Caption.cut(heard, at: .none, lineStarts: [0, 10, 20, 30, 40, 50], lastWord: 59)
        #expect(Caption.lines(heard, at: .none, lineStarts: [0, 10, 20, 30, 40, 50], lastWord: 59) == 6)
        #expect(Caption.lines(heard, at: cut, lineStarts: [20, 30, 40, 50], lastWord: 59) == 6)
        #expect(Caption.lines(heard, at: cut, lineStarts: [0, 10, 20, 30, 40, 50], lastWord: 59) == nil)
        #expect(Caption.lines(heard, at: .none, lineStarts: [0, 10, 20, 30, 40, 50], lastWord: 57) == nil)
    }

    @Test func the_newest_word_stays_full_and_the_one_before_it_settles_over_the_settle_time() {
        let first = CaptionSettle().updated(newest: 2, stopped: [0, 1, 2], gap: 0, reduceMotion: false)
        let next = first.updated(newest: 3, stopped: [2, 3], gap: 0.6, reduceMotion: false)

        #expect(next.brightness(3, after: 5) == 1)
        #expect(next.brightness(2, after: 0) == 1)
        #expect(next.brightness(2, after: PillMotion.captionSettle) == PillMotion.captionSettled)
        #expect(next.brightness(0, after: 0) == PillMotion.captionSettled)
        #expect(CaptionSettle().brightness(0, after: 0) == 1)
    }

    @Test func fresh_words_fade_in_in_reading_order_and_words_already_shown_stay_in() {
        let fresh = 3..<9
        let progress = { (index: Int, elapsed: Double) in
            Caption.revealProgress(index, fresh: fresh, firstDelay: PillMotion.wordDelay, elapsed: elapsed, reduceMotion: false)
        }
        let start = Caption.lastRevealStart(firstDelay: PillMotion.wordDelay)

        #expect(progress(2, 0) == 1)
        #expect(progress(3, 0) == 0)
        #expect(progress(3, start) > progress(4, start))
        #expect(progress(4, start) > progress(5, start))
        #expect(progress(6, start + 0.05) == progress(8, start + 0.05))
        #expect(progress(8, start + 2 * PillMotion.wordFade) == 1)
    }

    private static func words(_ range: Range<Int>) -> String {
        range.map { "w\($0)" }.joined(separator: " ")
    }
}
