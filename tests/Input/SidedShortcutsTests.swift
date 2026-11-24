import AppKit
import Carbon.HIToolbox
import NarrariKit
import Testing

// The key tap, the dictation key's monitor and the gesture together, fed the events macOS would send for each key.
@MainActor
private struct Keyboard {
    var tap: SidedShortcuts
    var gesture = HotkeyGesture(timing: .init(holdThreshold: 0.5, shortcutWindow: 0.2, minimumRecording: 0.3))
    var presses = ShortcutPresses()
    var isHotkeyDown = false
    var flags = NSEvent.ModifierFlags()
    var actions: [HotkeyGesture.Action] = []
    var fired: [SidedShortcuts.Target] = []
    var reachedApp: [UInt16] = []
    let hotkey = ModifierKey(keyCode: kVK_RightCommand)!

    static let rightCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)

    init(_ entries: [SidedShortcuts.Entry]) {
        tap = SidedShortcuts(entries: entries)
    }

    mutating func rightCommand(isDown: Bool, at time: TimeInterval) {
        flags = isDown ? Self.rightCommand : []
        monitor(KeyEvent(kind: .modifier, keyCode: UInt16(kVK_RightCommand), flags: flags), at: time)
    }

    mutating func key(_ keyCode: Int, isDown: Bool, at time: TimeInterval, isRepeat: Bool = false) {
        let code = UInt16(keyCode)
        switch tap.decide(isDown: isDown, keyCode: code, flags: flags, isRepeat: isRepeat) {
        case .swallow:
            return
        case .fire(let target):
            fired.append(target)
            presses.shortcutFired(at: time, isHotkeyHeld: flags.contains(Self.rightCommand), isHotkeyDown: isHotkeyDown)
            actions += gesture.handle(target == .cleanupToggle ? .cleanupToggle : .shortcut, at: time)
        case .pass:
            reachedApp.append(code)
            if isDown { monitor(KeyEvent(kind: .key, keyCode: code, flags: flags), at: time) }
        }
    }

    mutating func tick(at time: TimeInterval) {
        actions += gesture.handle(.tick, at: time)
    }

    private mutating func monitor(_ event: KeyEvent, at time: TimeInterval) {
        guard let input = HotkeyMonitor.input(for: event, hotkey: hotkey, isHotkeyDown: isHotkeyDown, cleanupToggle: nil, sided: tap)
        else { return }
        if input == .hotkeyDown || input == .hotkeyUp { isHotkeyDown = input == .hotkeyDown }
        guard let passed = presses.pass(input, at: time) else { return }
        actions += gesture.handle(passed, at: time)
    }
}

@MainActor
struct SidedShortcutsTests {
    private let m = kVK_ANSI_M
    private var meeting: SidedShortcuts.Entry {
        SidedShortcuts.Entry(Shortcut(keyCode: UInt16(m), flags: Keyboard.rightCommand), .live(.meeting))
    }

    @Test(arguments: [false, true])
    func right_command_m_fires_once_and_starts_nothing_whichever_key_is_let_go_first(commandFirst: Bool) {
        var keyboard = Keyboard([meeting])
        keyboard.rightCommand(isDown: true, at: 10)
        keyboard.key(m, isDown: true, at: 10.1)
        keyboard.key(m, isDown: true, at: 10.15, isRepeat: true)
        keyboard.tick(at: 10.25)
        if commandFirst { keyboard.rightCommand(isDown: false, at: 10.3) }
        keyboard.key(m, isDown: false, at: 10.4)
        if !commandFirst { keyboard.rightCommand(isDown: false, at: 10.5) }

        #expect(keyboard.fired == [.live(.meeting)])
        #expect(keyboard.actions == [.begin, .discard(.shortcut)])
        #expect(keyboard.reachedApp.isEmpty)
    }

    @Test func right_command_held_past_the_window_then_m_ends_the_dictation_quietly() {
        var keyboard = Keyboard([meeting])
        keyboard.rightCommand(isDown: true, at: 10)
        keyboard.tick(at: 10.25)
        keyboard.key(m, isDown: true, at: 10.6)
        keyboard.key(m, isDown: false, at: 10.7)
        keyboard.rightCommand(isDown: false, at: 10.8)

        #expect(keyboard.fired == [.live(.meeting)])
        #expect(keyboard.actions == [.begin, .confirm, .discard(.shortcut)])
    }

    @Test func m_held_before_right_command_fires_from_its_repeat_and_only_its_first_press_reached_the_app() {
        var keyboard = Keyboard([meeting])
        keyboard.key(m, isDown: true, at: 10)
        keyboard.rightCommand(isDown: true, at: 10.1)
        keyboard.key(m, isDown: true, at: 10.15, isRepeat: true)
        keyboard.key(m, isDown: true, at: 10.2, isRepeat: true)
        keyboard.key(m, isDown: false, at: 10.22)
        keyboard.rightCommand(isDown: false, at: 10.25)

        #expect(keyboard.fired == [.live(.meeting)])
        #expect(keyboard.reachedApp == [UInt16(m)])
        #expect(keyboard.actions == [.begin, .discard(.shortcut)])
    }

    @Test func m_typed_and_let_go_before_right_command_is_no_shortcut() {
        var keyboard = Keyboard([meeting])
        keyboard.key(m, isDown: true, at: 10)
        keyboard.key(m, isDown: false, at: 10.05)
        keyboard.rightCommand(isDown: true, at: 10.1)
        keyboard.tick(at: 10.3)
        keyboard.rightCommand(isDown: false, at: 10.8)

        #expect(keyboard.fired.isEmpty)
        #expect(keyboard.reachedApp == [UInt16(m), UInt16(m)])
        #expect(keyboard.actions == [.begin, .confirm, .stop])
    }

    @Test func a_tap_of_right_command_then_m_is_no_shortcut_and_m_reaches_the_app() {
        var keyboard = Keyboard([meeting])
        keyboard.rightCommand(isDown: true, at: 10)
        keyboard.rightCommand(isDown: false, at: 10.05)
        keyboard.key(m, isDown: true, at: 10.1)
        keyboard.key(m, isDown: false, at: 10.15)

        #expect(keyboard.fired.isEmpty)
        #expect(keyboard.reachedApp == [UInt16(m), UInt16(m)])
        #expect(keyboard.actions == [.begin, .discard(.shortcutKey)])
    }

    @Test func another_letter_with_right_command_still_reaches_the_app_and_cancels_as_before() {
        var keyboard = Keyboard([meeting])
        keyboard.rightCommand(isDown: true, at: 10)
        keyboard.key(kVK_ANSI_C, isDown: true, at: 10.1)

        #expect(keyboard.fired.isEmpty)
        #expect(keyboard.reachedApp == [UInt16(kVK_ANSI_C)])
        #expect(keyboard.actions == [.begin, .discard(.shortcutKey)])
    }

    @Test func a_report_that_overtakes_the_dictation_key_press_keeps_that_press_from_dictating() {
        var gesture = HotkeyGesture(timing: .init(holdThreshold: 0.5, shortcutWindow: 0.2, minimumRecording: 0.3))
        var presses = ShortcutPresses()
        presses.shortcutFired(at: 10.1, isHotkeyHeld: true, isHotkeyDown: false)
        var actions = gesture.handle(.shortcut, at: 10.1)

        for (input, time) in [(HotkeyGesture.Input.hotkeyDown, 10.0), (.hotkeyUp, 10.3), (.hotkeyDown, 12), (.hotkeyUp, 12.7)] {
            if let passed = presses.pass(input, at: time) { actions += gesture.handle(passed, at: time) }
        }

        #expect(actions == [.begin, .stop])
    }

    @Test func a_sided_clean_up_toggle_works_while_the_dictation_key_is_held_and_keeps_the_dictation() {
        let toggle = SidedShortcuts.Entry(
            Shortcut(keyCode: UInt16(kVK_ANSI_E), flags: Keyboard.rightCommand), .cleanupToggle, alsoWith: .command
        )
        var keyboard = Keyboard([toggle])
        keyboard.rightCommand(isDown: true, at: 10)
        keyboard.tick(at: 10.25)
        keyboard.key(kVK_ANSI_E, isDown: true, at: 10.3)
        keyboard.key(kVK_ANSI_E, isDown: false, at: 10.35)
        keyboard.rightCommand(isDown: false, at: 10.8)

        #expect(keyboard.actions == [.begin, .confirm, .toggleCleanup, .stop])
        #expect(keyboard.reachedApp.isEmpty)
    }

    @Test func the_dictation_key_held_with_another_modifier_lets_the_clean_up_toggle_match() {
        let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        let toggle = Shortcut(keyCode: UInt16(kVK_ANSI_E), flags: Keyboard.rightCommand)
        let flags = Keyboard.rightCommand.union(rightOption)

        #expect(toggle.matches(keyCode: UInt16(kVK_ANSI_E), flags: flags, alsoWith: .option))
        #expect(!toggle.matches(keyCode: UInt16(kVK_ANSI_E), flags: flags))
    }
}
