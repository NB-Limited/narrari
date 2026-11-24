import Carbon.HIToolbox
import NarrariKit
import Testing

@MainActor
struct ShortcutsCommandTests {
    private let settings = ThrowawaySettings()
    private let folder = TemporaryFolder()
    private let announced = Announcements()

    private func run(_ arguments: String...) async -> Command.Reply? {
        await Command(arguments: ["shortcuts"] + arguments)?.run(in: .throwaway(in: folder, settings: settings.store, announced: announced))
    }

    @Test func a_shortcut_typed_either_way_is_set_listed_and_announced() async {
        #expect(await run("set", "meeting", "ctrl+opt+f5")?.output == "meeting is now ⌃⌥F5.\n")
        #expect(await run("set", "open-settings", "⌘F6")?.status == 0)
        #expect(await run("set", "dictation", "right", "opt")?.output == "dictation is now Right ⌥.\n")

        #expect(LiveShortcut.meeting.shortcut(in: settings.store) == Shortcut(keyCode: kVK_F5, modifiers: controlKey | optionKey))
        #expect(settings.store.value(DictationSettings.hotkeyKeyCode) == 61)
        #expect(announced.all.prefix(2) == [MeetingsSettings.hotkeyKeyCode.key, MeetingsSettings.hotkeyModifiers.key])
        let listed = await run()?.output ?? ""
        #expect(listed.contains("meeting        ⌃⌥F5\n"))
        #expect(listed.contains("next-mode      None\n"))
    }

    @Test func a_right_hand_key_is_named_in_words_and_listed_with_its_side() async {
        #expect(await run("set", "meeting", "right-cmd+f5")?.output == "meeting is now Right ⌘ F5.\n")

        #expect(LiveShortcut.meeting.shortcut(in: settings.store)?.isSided == true)
        #expect(await run("set", "paste-last", "cmd+f5")?.status == 1)
    }

    @Test func a_clash_is_refused_as_the_shortcuts_page_refuses_it() async {
        #expect(await run("set", "paste-last", "ctrl+opt+f5")?.status == 0)

        let reply = await run("set", "meeting", "⌃⌥F5")

        #expect(reply?.status == 1)
        #expect(reply?.errors == "⌃⌥F5 already pastes the last dictation. Choose another.\n")
        #expect(LiveShortcut.meeting.shortcut(in: settings.store) == nil)
        #expect(await run("set", "meeting", "shift+f5")?.errors == "Add ⌘, ⌥ or ⌃ to the key, such as ⌘E.\n")
        #expect(announced.all == [DictationSettings.pasteLastKeyCode.key, DictationSettings.pasteLastModifiers.key])
    }

    @Test func clearing_works_only_where_the_page_offers_clear() async {
        #expect(await run("set", "next-mode", "ctrl+f7")?.status == 0)

        #expect(await run("clear", "next-mode")?.output == "next-mode has no shortcut now.\n")
        #expect(LiveShortcut.mode.shortcut(in: settings.store) == nil)
        #expect(await run("clear", "dictation")?.status == 1)
        #expect(await run("set", "dictation", "caps")?.errors.hasPrefix("caps is not a key for dictation. Use one of") == true)
        #expect(await run("set", "warp", "ctrl+f7")?.errors.hasPrefix("warp is not a shortcut. The shortcuts are: dictation, cleanup") == true)
    }
}
