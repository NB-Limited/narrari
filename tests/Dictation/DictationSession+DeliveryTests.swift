import Foundation
import NarrariKit
import Testing

@MainActor
struct DictationSessionDeliveryTests {
    @Test func pastes_the_cleaned_text_and_gives_the_clipboard_back() async throws {
        let rig = SessionRig()

        await rig.dictate()

        #expect(rig.pastes.map(\.text) == ["Hello from the test."])
        #expect(rig.pasteboard.text == "copied by the user")
        let entry = try await rig.onlyEntry()
        #expect(entry.outcome == .pasted)
        #expect(entry.rawText == "hello from the test")
        #expect(entry.finalText == "Hello from the test.")
    }

    @Test func missing_cleanup_model_pastes_the_raw_transcript_and_history_says_why() async throws {
        let rig = SessionRig(engine: FakeCleanupEngine(state: .missing) { _ in "never asked" })

        await rig.dictate()

        #expect(rig.pastes.map(\.text) == ["hello from the test"])
        #expect(rig.session.notice == .cleanupSkipped(.modelUnavailable))
        let entry = try await rig.onlyEntry()
        #expect(entry.cleanup.status == CleanupResult.Status.skipped.rawValue)
        #expect(entry.cleanup.reason == CleanupResult.Reason.modelUnavailable.rawValue)
        #expect(entry.isCleanupSkipped)
    }

    @Test func paste_without_accessibility_leaves_the_text_on_the_clipboard() async throws {
        let rig = SessionRig(access: .fixed(accessibility: false))

        await rig.dictate()

        #expect(rig.pastes.isEmpty)
        #expect(rig.pasteboard.text == "Hello from the test.")
        #expect(rig.session.notice == .copiedAccessibilityOff)
        #expect(try await rig.onlyEntry().outcome == .clipboard)
        #expect(rig.session.phase == .idle)
    }

    @Test func cleanup_toggle_during_a_dictation_pastes_it_as_spoken() async throws {
        let engine = FakeCleanupEngine { _ in "Hello from the test." }
        let rig = SessionRig(engine: engine)
        await rig.pressAndConfirm()

        rig.hotkeys.send(.cleanupToggle, at: rig.clock.seconds)
        rig.release()
        await rig.session.shutdown()

        #expect(engine.calls.isEmpty)
        #expect(rig.pastes.map(\.text) == ["hello from the test"])
        #expect(try await rig.onlyEntry().cleanup.reason == CleanupResult.Reason.hotkey.rawValue)
    }
}
