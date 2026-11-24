import NarrariKit
import Testing

struct DropdownListTests {
    private let microphones = ["MacBook Pro Microphone", "Studio Display", "Shure MV7", "Scarlett 2i2", "Élan"]

    @Test func opens_on_the_current_choice_and_the_arrows_stop_at_the_ends() {
        var list = DropdownList(titles: microphones, chosen: 3)
        #expect(list.highlighted == 3)

        list.move(by: 1)
        list.move(by: 1)
        list.move(by: 1)
        #expect(list.highlighted == 4)

        list.moveToEnd(last: false)
        list.move(by: -1)
        #expect(list.highlighted == 0)
    }

    @Test func with_no_choice_it_opens_on_the_first_row() {
        #expect(DropdownList(titles: microphones, chosen: nil).highlighted == 0)
        #expect(DropdownList(titles: [], chosen: nil).highlighted == nil)
    }

    @Test func typing_jumps_to_the_first_name_that_starts_with_the_letters() {
        var list = DropdownList(titles: microphones, chosen: 0)

        list.type("s", at: 10)
        #expect(list.highlighted == 1)
        list.type("c", at: 10.4)
        #expect(list.highlighted == 3)

        list.type("e", at: 12)
        #expect(list.highlighted == 4)
    }

    @Test func the_same_letter_again_steps_through_the_names_that_start_with_it() {
        var list = DropdownList(titles: microphones, chosen: 0)

        list.type("s", at: 1)
        list.type("s", at: 1.2)
        #expect(list.highlighted == 2)
        list.type("s", at: 1.4)
        #expect(list.highlighted == 3)
        list.type("s", at: 1.6)
        #expect(list.highlighted == 1)
    }

    @Test func a_letter_nothing_starts_with_leaves_the_highlight() {
        var list = DropdownList(titles: microphones, chosen: 2)
        list.type("z", at: 1)
        #expect(list.highlighted == 2)
    }
}
