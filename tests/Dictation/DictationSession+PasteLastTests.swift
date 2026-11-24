import Foundation
import NarrariKit
import Testing

@MainActor
struct DictationSessionPasteLastTests {
    private let newer = [[PasteboardEntry(type: .string, data: Data("copied after the dictation".utf8))]]

    @Test func pastes_the_last_dictation_again_and_gives_the_clipboard_back() async throws {
        let rig = SessionRig()
        await rig.dictate()
        rig.pasteboard.replace(with: newer)

        await rig.session.pasteLast(try await rig.onlyEntry().finalText)
        await rig.session.shutdown()

        #expect(rig.pastes.map(\.text) == ["Hello from the test.", "Hello from the test."])
        #expect(rig.pasteboard.items() == newer)
        #expect(rig.session.isDone)
        #expect(try await rig.entries().count == 1)
    }

    @Test func with_no_dictation_it_says_so_and_pastes_nothing() async {
        let rig = SessionRig()

        await rig.session.pasteLast(nil)

        #expect(rig.pastes.isEmpty)
        #expect(rig.session.notice == .nothingToPaste)
        #expect(rig.pasteboard.text == "copied by the user")
    }

    @Test func during_a_dictation_it_leaves_the_dictation_and_its_saved_clipboard_alone() async throws {
        let heard = Gate()
        let rig = SessionRig(transcriber: FakeTranscriber(text: "hello from the test", gate: heard))
        await rig.pressAndConfirm()

        await rig.session.pasteLast("an older dictation")
        rig.release()
        await heard.waitForArrivals(1)
        await rig.session.pasteLast("an older dictation")
        heard.open()
        await rig.session.shutdown()

        #expect(rig.pastes.map(\.text) == ["Hello from the test."])
        #expect(rig.pasteboard.text == "copied by the user")
        #expect(try await rig.onlyEntry().outcome == .pasted)
    }

    @Test(arguments: [false, true])
    func a_paste_that_fails_leaves_the_text_on_the_clipboard_and_says_so(_ isAccessibilityOn: Bool) async {
        let rig = SessionRig(access: .fixed(accessibility: isAccessibilityOn))
        rig.makesKeystroke = false

        await rig.session.pasteLast("Hello again.")
        await rig.session.shutdown()

        #expect(rig.pasteboard.items() == [[PasteboardEntry(type: .string, data: Data("Hello again.".utf8))]])
        #expect(rig.session.notice == (isAccessibilityOn ? .copiedKeystrokeFailed : .copiedAccessibilityOff))
        #expect(!rig.session.isDone)
    }
}
