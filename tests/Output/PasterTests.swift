import AppKit
import NarrariKit
import os
import Testing

@MainActor
struct PasterTests {
    private let clock = TestClock()
    private let settings = ThrowawaySettings()
    private let saved: [[PasteboardEntry]] = [
        [PasteboardEntry(type: .string, data: Data("quarterly numbers".utf8)), PasteboardEntry(type: .rtf, data: Data("{\\rtf1 quarterly}".utf8))],
        [PasteboardEntry(type: .png, data: Data([0x89, 0x50, 0x4E, 0x47]))]
    ]
    private let pasteboard: FakePasteboard
    private let pastes = Counter()

    init() {
        pasteboard = FakePasteboard(saved)
    }

    private func paster(_ access: InputAccess = .fixed()) -> Paster {
        Paster(pasteboard: pasteboard, access: access, settings: settings.store, postPaste: { [pastes] in
            pastes.posted += 1
            return true
        }, clock: clock)
    }

    @Test func clipboard_comes_back_with_every_item_and_type_one_second_after() async {
        let paster = paster()

        #expect(await paster.paste("Hello, Anna.") == .pasted)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(999))
        #expect(pasteboard.text == "Hello, Anna.")
        clock.advance(by: .milliseconds(1))
        await paster.finishRestore()

        #expect(pastes.posted == 1)
        #expect(pasteboard.items() == saved)
    }

    @Test(arguments: [false, true])
    func clipboard_saved_while_speaking_comes_back_unless_something_newer_was_copied(_ copiedWhileSpeaking: Bool) async {
        let paster = paster()
        paster.saveClipboard()
        let newer = [[PasteboardEntry(type: .string, data: Data("copied while speaking".utf8))]]
        if copiedWhileSpeaking { pasteboard.replace(with: newer) }

        _ = await paster.paste("Hello, Anna.")
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await paster.finishRestore()

        #expect(pasteboard.items() == (copiedWhileSpeaking ? newer : saved))
    }

    @Test func temporary_text_is_marked_for_clipboard_managers() async {
        let paster = paster()

        _ = await paster.paste("Hello, Anna.")

        let types = pasteboard.items().first?.map(\.type) ?? []
        #expect(types.contains(Paster.transientType))
        #expect(types.contains(Paster.concealedType))
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await paster.finishRestore()
    }

    @Test func something_copied_after_the_paste_is_not_overwritten() async {
        let paster = paster()
        _ = await paster.paste("Hello, Anna.")
        await clock.waitForSleepers(1)

        let copied = [[PasteboardEntry(type: .string, data: Data("copied just now".utf8))]]
        pasteboard.replace(with: copied)
        clock.advance(by: .seconds(1))
        await paster.finishRestore()

        #expect(pasteboard.items() == copied)
    }

    @Test func paste_without_accessibility_only_copies_the_text() async {
        let paster = paster(.fixed(accessibility: false))

        #expect(await paster.paste("Hello, Anna.") == .copiedAccessibilityOff)

        #expect(pastes.posted == 0)
        #expect(pasteboard.items() == [[PasteboardEntry(type: .string, data: Data("Hello, Anna.".utf8))]])
        #expect(clock.pendingSleepers == 0)
    }

    @Test func paste_waits_until_the_shortcut_keys_are_released() async {
        let held = OSAllocatedUnfairLock(initialState: true)
        let paster = paster(.fixed(modifiersHeld: { held.withLock { $0 } }))
        let pasting = Task { await paster.paste("Hello, Anna.") }

        await clock.waitForSleepers(1)
        #expect(pastes.posted == 0)
        #expect(pasteboard.items() == saved)
        held.withLock { $0 = false }
        clock.advance(by: .milliseconds(20))

        #expect(await pasting.value == .pasted)
        #expect(pastes.posted == 1)
    }

    @Test func paste_goes_ahead_after_a_second_of_held_keys() async {
        let paster = paster(.fixed(modifiersHeld: { true }))
        let pasting = Task { await paster.paste("Hello, Anna.") }

        for _ in 1...50 {
            await clock.waitForSleepers(1)
            #expect(pastes.posted == 0)
            clock.advance(by: .milliseconds(20))
        }

        #expect(await pasting.value == .pasted)
        #expect(pastes.posted == 1)
    }

    @Test func two_pastes_waiting_on_the_same_restore_still_give_the_clipboard_back() async {
        let paster = paster()
        _ = await paster.paste("first")
        await clock.waitForSleepers(1)
        let second = Task { await paster.paste("second") }
        let third = Task { await paster.paste("third") }

        // Each restore must end before the next paste reads the clipboard, so one restore waits at a time.
        for _ in 1...2 {
            clock.advance(by: .seconds(1))
            await clock.waitForSleeper(until: clock.now.advanced(by: .seconds(1)))
        }
        clock.advance(by: .seconds(1))
        _ = await (second.value, third.value)
        await paster.finishRestore()

        #expect(pastes.posted == 3)
        #expect(pasteboard.items() == saved)
    }
}

@MainActor
private final class Counter {
    var posted = 0
}
