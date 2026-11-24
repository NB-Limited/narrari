import Carbon.HIToolbox
import NarrariKit
import Observation
import Testing

@MainActor
struct SettingsMirrorTests {
    private let settings = ThrowawaySettings()

    // Whoever writes the store, the window included, announces the key; whatever read it through the mirror redraws.
    @Test(.timeLimit(.minutes(1))) func a_setting_written_elsewhere_redraws_what_read_it() async {
        let mirror = settings.mirror
        let page = ShortcutsPageModel(settings: mirror)

        await confirmation { redrawn in
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = page.liveShortcuts
                } onChange: {
                    redrawn()
                    continuation.resume()
                }
                LiveShortcut.meeting.store(Shortcut(keyCode: kVK_F5, modifiers: controlKey | optionKey), in: settings.store)
            }
        }
        #expect(page.liveShortcuts[.meeting] == Shortcut(keyCode: kVK_F5, modifiers: controlKey | optionKey))
    }
}
