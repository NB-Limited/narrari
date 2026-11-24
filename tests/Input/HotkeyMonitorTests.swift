import AppKit
import Carbon.HIToolbox
import NarrariKit
import Testing

@MainActor
struct HotkeyMonitorTests {
    private let settings = ThrowawaySettings()
    private let rightCommand = ModifierKey(keyCode: 54)!
    private let leftCommandDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08)
    private let bothCommandsDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x18)
    private let rightCommandDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)

    private func input(_ kind: KeyEvent.Kind, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, held: Bool, toggle: Shortcut? = nil) -> HotkeyGesture.Input? {
        HotkeyMonitor.input(for: KeyEvent(kind: kind, keyCode: keyCode, flags: flags), hotkey: rightCommand, isHotkeyDown: held, cleanupToggle: toggle)
    }

    @Test func hotkeys_stay_suspended_until_the_last_suspension_is_gone() {
        let permissions = Permissions.fixed(settings: settings.store)
        let monitor = HotkeyMonitor(settings: settings.store, permissions: permissions)
        let first = monitor.suspend()
        var second: HotkeySuspension? = monitor.suspend()

        withExtendedLifetime(second) {
            first.end()
            #expect(monitor.isSuspended)
        }
        second = nil

        #expect(!monitor.isSuspended)
    }

    @Test func right_command_is_told_apart_from_left_command() {
        #expect(input(.modifier, 54, rightCommandDown, held: false) == .hotkeyDown)
        #expect(input(.modifier, 55, leftCommandDown, held: false) == .otherKey)
        #expect(input(.modifier, 54, leftCommandDown, held: true) == .hotkeyUp)
        #expect(input(.modifier, 54, rightCommandDown, held: true) == nil)
    }

    @Test func another_modifier_pressed_while_holding_counts_as_another_key_and_its_release_does_not() {
        #expect(input(.modifier, 55, bothCommandsDown, held: true) == .otherKey)
        let rightCommandAndLeftShift = NSEvent.ModifierFlags(rawValue: rightCommandDown.rawValue | NSEvent.ModifierFlags.shift.rawValue | 0x02)
        #expect(input(.modifier, 56, rightCommandAndLeftShift, held: true) == .otherKey)
        #expect(input(.modifier, 56, rightCommandDown, held: true) == nil)
        #expect(input(.key, UInt16(kVK_ANSI_A), rightCommandDown, held: true) == .otherKey)
    }

    @Test func clean_up_toggle_passes_through_while_holding() {
        let toggle = Shortcut(keyCode: kVK_ANSI_E, modifiers: cmdKey)

        #expect(input(.key, UInt16(kVK_ANSI_E), rightCommandDown, held: true, toggle: toggle) == nil)
        #expect(input(.key, UInt16(kVK_ANSI_E), [], held: true, toggle: toggle) == .otherKey)
    }

    @Test func a_key_the_tap_reports_itself_is_not_another_key_while_holding() {
        let meeting = Shortcut(keyCode: UInt16(kVK_ANSI_M), flags: rightCommandDown)
        let tap = SidedShortcuts(entries: [.init(meeting, .live(.meeting))])
        let event = KeyEvent(kind: .key, keyCode: UInt16(kVK_ANSI_M), flags: rightCommandDown)

        #expect(HotkeyMonitor.input(for: event, hotkey: rightCommand, isHotkeyDown: true, cleanupToggle: nil, sided: tap) == nil)
        #expect(HotkeyMonitor.input(for: event, hotkey: rightCommand, isHotkeyDown: true, cleanupToggle: nil) == .otherKey)
    }
}
