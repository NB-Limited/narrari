import AppKit
import Carbon.HIToolbox
import NarrariKit
import Testing

@MainActor
struct ShortcutTests {
    private let rightCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
    private let leftCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08)
    private let bothCommands = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x18)
    private let leftShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x02)
    private let m = UInt16(kVK_ANSI_M)

    @Test func a_right_hand_modifier_records_its_side_and_a_left_hand_or_both_record_either_side() {
        let right = Shortcut(keyCode: m, flags: rightCommand)
        let left = Shortcut(keyCode: m, flags: leftCommand)
        let both = Shortcut(keyCode: m, flags: bothCommands)
        let mixed = Shortcut(keyCode: m, flags: rightCommand.union(leftShift))

        #expect(right.isSided && right.carbonModifiers == cmdKey)
        #expect(!left.isSided && left == Shortcut(keyCode: kVK_ANSI_M, modifiers: cmdKey))
        #expect(!both.isSided)
        #expect(mixed.isSided && mixed.carbonModifiers == cmdKey | shiftKey)
    }

    @Test func a_right_only_shortcut_matches_the_right_key_alone_and_an_old_one_matches_either() {
        let right = Shortcut(keyCode: m, flags: rightCommand)
        let stored = Shortcut(keyCode: kVK_ANSI_M, modifiers: cmdKey)

        #expect(right.matches(keyCode: m, flags: rightCommand))
        #expect(right.matches(keyCode: m, flags: bothCommands))
        #expect(!right.matches(keyCode: m, flags: leftCommand))
        #expect(!right.matches(keyCode: m, flags: rightCommand.union(leftShift)))
        #expect(!right.matches(keyCode: UInt16(kVK_ANSI_N), flags: rightCommand))
        #expect(stored.matches(keyCode: m, flags: leftCommand) && stored.matches(keyCode: m, flags: rightCommand))
    }

    @Test func the_stored_form_keeps_the_carbon_mask_that_versions_before_sides_read() {
        let right = Shortcut(keyCode: m, flags: rightCommand)
        let reloaded = Shortcut(keyCode: right.keyCode, modifiers: right.modifiers)

        #expect(reloaded == right && reloaded.isSided)
        #expect(right.modifiers & 0xFFFF == cmdKey)
    }

    @Test func shortcuts_on_the_same_key_and_modifiers_clash_whatever_their_sides() {
        let right = Shortcut(keyCode: m, flags: rightCommand)

        #expect(right.clashes(with: Shortcut(keyCode: kVK_ANSI_M, modifiers: cmdKey)))
        #expect(right.clashes(with: Shortcut(keyCode: m, flags: rightCommand)))
        #expect(!right.clashes(with: Shortcut(keyCode: kVK_ANSI_M, modifiers: cmdKey | shiftKey)))
        #expect(!right.clashes(with: Shortcut(keyCode: kVK_ANSI_N, modifiers: cmdKey)))
    }

    @Test func a_sided_shortcut_reads_like_the_dictation_key_and_one_without_sides_reads_as_before() {
        let f5 = UInt16(kVK_F5)

        #expect(HotkeyName.name(of: Shortcut(keyCode: f5, flags: rightCommand)) == "Right ⌘ F5")
        #expect(HotkeyName.name(of: Shortcut(keyCode: f5, flags: rightCommand.union(leftShift))) == "⇧ Right ⌘ F5")
        #expect(HotkeyName.name(of: Shortcut(keyCode: f5, flags: leftCommand.union(leftShift))) == "⇧⌘F5")
    }
}
