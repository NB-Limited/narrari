import NarrariKit
import Testing

struct HotkeyGestureTests {
    private var gesture = HotkeyGesture(timing: .init(holdThreshold: 0.5, shortcutWindow: 0.2, minimumRecording: 0.3))

    private mutating func feed(_ inputs: [(HotkeyGesture.Input, Double)]) -> [HotkeyGesture.Action] {
        inputs.flatMap { gesture.handle($0.0, at: $0.1) }
    }

    @Test mutating func hold_of_half_a_second_stops_on_release() {
        let actions = feed([(.hotkeyDown, 10), (.tick, 10.25), (.hotkeyUp, 10.5)])

        #expect(actions == [.begin, .confirm, .stop])
    }

    @Test mutating func short_press_goes_hands_free_until_the_next_press() {
        let actions = feed([(.hotkeyDown, 10), (.tick, 10.25), (.hotkeyUp, 10.49)])
        #expect(actions == [.begin, .confirm])

        #expect(feed([(.hotkeyDown, 13), (.hotkeyUp, 13.1)]) == [.stop])
    }

    @Test(arguments: [false, true])
    mutating func another_key_in_the_shortcut_window_discards_before_anything_is_confirmed(afterRelease: Bool) {
        var inputs: [(HotkeyGesture.Input, Double)] = [(.hotkeyDown, 10)]
        if afterRelease { inputs.append((.hotkeyUp, 10.05)) }
        inputs += [(.otherKey, 10.15), (.tick, 10.25)]

        #expect(feed(inputs) == [.begin, .discard(.shortcutKey)])
    }

    @Test mutating func another_key_after_the_window_while_held_discards() {
        let actions = feed([(.hotkeyDown, 10), (.tick, 10.25), (.otherKey, 10.4)])

        #expect(actions == [.begin, .confirm, .discard(.keyWhileHeld)])
    }

    @Test(arguments: [false, true])
    mutating func escape_discards(handsFree: Bool) {
        var inputs: [(HotkeyGesture.Input, Double)] = [(.hotkeyDown, 10), (.tick, 10.25)]
        if handsFree { inputs.append((.hotkeyUp, 10.3)) }
        inputs.append((.escape, 11))

        #expect(feed(inputs) == [.begin, .confirm, .discard(.escape)])
    }

    @Test mutating func recording_shorter_than_the_minimum_discards() {
        let actions = feed([(.hotkeyDown, 10), (.hotkeyUp, 10.1), (.hotkeyDown, 10.25)])

        #expect(actions == [.begin, .discard(.tooShort)])
    }

    @Test mutating func other_keys_in_hands_free_after_the_window_are_ignored() {
        _ = feed([(.hotkeyDown, 10), (.hotkeyUp, 10.1), (.tick, 10.25)])

        #expect(feed([(.otherKey, 11), (.otherKey, 12)]).isEmpty)
        #expect(feed([(.hotkeyDown, 13)]) == [.stop])
    }

    @Test mutating func cleanup_toggle_acts_only_while_recording() {
        #expect(feed([(.cleanupToggle, 9)]).isEmpty)

        let actions = feed([(.hotkeyDown, 10), (.cleanupToggle, 10.3), (.hotkeyUp, 10.6)])

        #expect(actions == [.begin, .toggleCleanup, .stop])
    }

    @Test mutating func menu_toggle_starts_confirmed_and_the_next_toggle_stops() {
        #expect(gesture.toggle(at: 10) == [.begin, .confirm])
        #expect(gesture.toggle(at: 12) == [.stop])
        #expect(gesture.toggle(at: 20) == [.begin, .confirm])
        #expect(gesture.toggle(at: 20.1) == [.discard(.tooShort)])
    }

    @Test mutating func a_narrari_shortcut_while_held_discards_as_a_shortcut_even_after_the_window() {
        #expect(feed([(.hotkeyDown, 10), (.shortcut, 10.1)]) == [.begin, .discard(.shortcut)])

        let late = feed([(.hotkeyDown, 20), (.tick, 20.25), (.shortcut, 20.6), (.hotkeyUp, 20.7)])

        #expect(late == [.begin, .confirm, .discard(.shortcut)])
    }

    @Test mutating func a_narrari_shortcut_in_hands_free_after_the_window_leaves_the_dictation_running() {
        _ = feed([(.hotkeyDown, 10), (.hotkeyUp, 10.1), (.tick, 10.25)])

        #expect(feed([(.shortcut, 11)]).isEmpty)
        #expect(feed([(.hotkeyDown, 13)]) == [.stop])
    }
}
