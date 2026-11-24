import AppKit
import Carbon.HIToolbox
import NarrariKit
import Testing

@MainActor
struct ShortcutsPageModelTests {
    private let settings = ThrowawaySettings()

    private func page(_ monitor: HotkeyMonitor) -> ShortcutsPageModel {
        ShortcutsPageModel(settings: settings.mirror) { monitor.suspend() }
    }

    @Test func switching_fields_while_recording_resumes_hotkeys_once_recording_ends() {
        let permissions = Permissions(settings: settings.store, access: .fixed(), microphoneStatus: { .authorized })
        let monitor = HotkeyMonitor(settings: settings.store, permissions: permissions)
        let page = page(monitor)

        page.beginRecording(.cleanupToggle)
        page.beginRecording(.live(.mode))
        #expect(monitor.isSuspended)
        page.endRecording()

        #expect(!monitor.isSuspended)
    }

    @Test func page_that_goes_away_while_recording_gives_the_hotkeys_back() {
        let permissions = Permissions(settings: settings.store, access: .fixed(), microphoneStatus: { .authorized })
        let monitor = HotkeyMonitor(settings: settings.store, permissions: permissions)
        var page: ShortcutsPageModel? = page(monitor)
        page?.beginRecording(.dictation)
        #expect(monitor.isSuspended)

        page = nil

        #expect(!monitor.isSuspended)
    }

    private let openShortcut = Shortcut(keyCode: kVK_ANSI_K, modifiers: cmdKey)

    private func plainPage() -> ShortcutsPageModel {
        ShortcutsPageModel(settings: settings.mirror)
    }

    @Test func open_window_shortcut_is_unset_until_recorded_and_survives_a_reload() {
        let page = plainPage()
        #expect(page.liveShortcuts[.openWindow] == nil)

        page.record(openShortcut, for: .live(.openWindow))

        #expect(page.liveShortcuts[.openWindow] == openShortcut)
        #expect(plainPage().liveShortcuts[.openWindow] == openShortcut)
    }

    @Test func open_settings_shortcut_starts_unset_refuses_the_open_window_shortcut_and_clears() {
        let page = plainPage()
        let settingsShortcut = Shortcut(keyCode: kVK_ANSI_Comma, modifiers: cmdKey | optionKey)
        page.record(openShortcut, for: .live(.openWindow))
        let unset = page.liveShortcuts[.openSettings]

        page.record(openShortcut, for: .live(.openSettings))
        let refused = page.shortcutErrors[.live(.openSettings)]
        page.record(settingsShortcut, for: .live(.openSettings))
        let kept = plainPage().liveShortcuts[.openSettings]
        page.clear(.openSettings)

        #expect(unset == nil && kept == settingsShortcut)
        #expect(refused == "\(HotkeyName.name(of: openShortcut)) already opens Narrari. Choose another.")
        #expect(page.liveShortcuts[.openSettings] == nil && plainPage().liveShortcuts[.openSettings] == nil)
    }

    @Test func open_window_shortcut_cannot_reuse_the_clean_up_or_mode_shortcut() {
        let page = plainPage()
        let mode = Shortcut(keyCode: kVK_ANSI_M, modifiers: cmdKey | shiftKey)
        page.record(mode, for: .live(.mode))

        page.record(page.cleanupToggle, for: .live(.openWindow))
        #expect(page.liveShortcuts[.openWindow] == nil)
        #expect(page.shortcutErrors[.live(.openWindow)] != nil)

        page.record(mode, for: .live(.openWindow))
        #expect(page.liveShortcuts[.openWindow] == nil)
        #expect(page.shortcutErrors[.live(.openWindow)] != nil)
    }

    @Test func clean_up_and_mode_shortcuts_cannot_reuse_the_open_window_shortcut() {
        let page = plainPage()
        page.record(openShortcut, for: .live(.openWindow))

        page.record(openShortcut, for: .cleanupToggle)
        page.record(openShortcut, for: .live(.mode))

        #expect(page.cleanupToggle != openShortcut)
        #expect(page.liveShortcuts[.mode] == nil)
        #expect(page.shortcutErrors[.cleanupToggle] != nil)
        #expect(page.shortcutErrors[.live(.mode)] != nil)
    }

    @Test func clearing_the_open_window_shortcut_unsets_it_and_announces_the_change() async {
        let page = plainPage()
        page.record(openShortcut, for: .live(.openWindow))
        var updates = SettingsChanges.updates(of: [WindowSettings.openHotkeyKeyCode.key, WindowSettings.openHotkeyModifiers.key]).makeAsyncIterator()

        page.clear(.openWindow)
        await updates.next()

        #expect(page.liveShortcuts[.openWindow] == nil)
        #expect(settings.store.value(WindowSettings.openHotkeyKeyCode) < 0)
        #expect(plainPage().liveShortcuts[.openWindow] == nil)
    }

    @Test func paste_last_shortcut_starts_as_control_option_v_and_clearing_it_turns_it_off() async {
        let page = plainPage()
        #expect(page.liveShortcuts[.pasteLast] == Shortcut(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey))
        var updates = SettingsChanges.updates(of: [DictationSettings.pasteLastKeyCode.key]).makeAsyncIterator()

        page.clear(.pasteLast)
        await updates.next()

        #expect(settings.store.value(DictationSettings.pasteLastKeyCode) < 0)
        #expect(plainPage().liveShortcuts[.pasteLast] == nil)
        page.record(page.cleanupToggle, for: .live(.pasteLast))
        #expect(page.liveShortcuts[.pasteLast] == nil)
        #expect(page.shortcutErrors[.live(.pasteLast)] != nil)
    }

    @Test func recording_the_open_window_shortcut_announces_the_change() async {
        let page = plainPage()
        var updates = SettingsChanges.updates(of: [WindowSettings.openHotkeyKeyCode.key]).makeAsyncIterator()

        page.record(openShortcut, for: .live(.openWindow))

        #expect(await updates.next() != nil)
    }

    @Test func recording_the_open_window_shortcut_suspends_the_hotkeys_until_it_ends() {
        let permissions = Permissions(settings: settings.store, access: .fixed(), microphoneStatus: { .authorized })
        let monitor = HotkeyMonitor(settings: settings.store, permissions: permissions)
        let page = page(monitor)

        page.beginRecording(.live(.openWindow))
        #expect(monitor.isSuspended)
        page.record(openShortcut, for: .live(.openWindow))

        #expect(!monitor.isSuspended)
    }

    private let rightCommandM = Shortcut(
        keyCode: UInt16(kVK_ANSI_M), flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
    )

    @Test func a_right_hand_shortcut_survives_a_reload_and_clashes_with_the_same_keys_without_a_side() {
        let page = plainPage()
        page.record(rightCommandM, for: .live(.meeting))

        page.record(Shortcut(keyCode: kVK_ANSI_M, modifiers: cmdKey), for: .live(.openWindow))

        #expect(plainPage().liveShortcuts[.meeting] == rightCommandM)
        #expect(page.liveShortcuts[.openWindow] == nil)
        #expect(page.shortcutErrors[.live(.openWindow)] == "\(HotkeyName.name(of: rightCommandM)) already starts or stops a meeting. Choose another.")
    }

    @Test func right_hand_shortcuts_show_as_not_working_when_the_key_tap_was_refused() {
        settings.store.set(rightCommandM.keyCode, for: MeetingsSettings.hotkeyKeyCode)
        settings.store.set(rightCommandM.modifiers, for: MeetingsSettings.hotkeyModifiers)
        let refused = ShortcutsPageModel(settings: settings.mirror, sidedState: { .notWorking })
        let working = ShortcutsPageModel(settings: settings.mirror, sidedState: { .working })

        #expect(refused.sidedProblem != nil && working.sidedProblem == nil)
        #expect(refused.isNotWorking(.live(.meeting)) && !working.isNotWorking(.live(.meeting)))
        #expect(!refused.isNotWorking(.live(.pasteLast)) && !refused.isNotWorking(.cleanupToggle))
    }
}
