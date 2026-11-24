import Foundation
import NarrariKit
import Testing

@MainActor
struct DictationSessionModesTests {
    @Test func mode_chosen_at_start_holds_when_the_frontmost_app_changes() async throws {
        let engine = FakeCleanupEngine { _ in "Dear Anna, hello." }
        let rig = SessionRig(engine: engine)
        try rig.modes.edit { book in
            try book.add(Mode(id: "mail", name: "Mail", promptID: Prompt.email.id))
            try book.setModes(for: "com.apple.mail", ids: ["mail"], defaultID: "mail")
        }
        rig.frontmost = "com.apple.mail"
        await rig.pressAndConfirm()

        rig.frontmost = "com.tinyspeck.slackmacgap"
        rig.session.frontmostAppChanged()
        rig.release()
        await rig.session.shutdown()

        #expect(engine.calls.first?.instruction.contains(Prompt.email.instruction) == true)
        let entry = try await rig.onlyEntry()
        #expect(entry.mode == "Mail")
        #expect(entry.app == "com.apple.mail")
    }

    @Test func dictating_from_a_narrari_window_goes_to_the_app_used_before_it() async throws {
        let rig = SessionRig()
        try rig.modes.edit { book in
            try book.add(Mode(id: "mail", name: "Mail", promptID: Prompt.email.id))
            try book.setModes(for: "com.apple.mail", ids: ["mail"], defaultID: "mail")
        }
        rig.frontmost = "com.apple.mail"
        rig.session.frontmostAppChanged()
        rig.frontmost = SessionRig.ownApp
        rig.session.frontmostAppChanged()

        await rig.dictate()

        let entry = try await rig.onlyEntry()
        #expect(entry.app == "com.apple.mail")
        #expect(entry.mode == "Mail")
    }

    @Test func dictating_from_a_narrari_window_with_no_app_before_uses_the_global_default() async throws {
        let rig = SessionRig()
        try rig.modes.edit { book in
            try book.add(Mode(id: "notes", name: "Notes", isCleanupOn: false))
            try book.setModes(for: SessionRig.ownApp, ids: ["notes"], defaultID: "notes")
        }
        rig.frontmost = SessionRig.ownApp

        await rig.dictate()

        let entry = try await rig.onlyEntry()
        #expect(entry.app.isEmpty)
        #expect(entry.mode == "Dictation")
    }

    @Test func mode_key_while_idle_switches_the_mode_for_the_next_dictation() async throws {
        let rig = SessionRig()
        try rig.modes.edit { book in
            try book.add(Mode(id: "mail", name: "Mail", promptID: Prompt.email.id))
            try book.setModes(for: "com.apple.TextEdit", ids: [Mode.dictation.id, "mail"], defaultID: Mode.dictation.id)
        }

        rig.session.cycleMode()
        #expect(rig.session.notice == .mode("Mail"))
        await rig.dictate()

        #expect(try await rig.onlyEntry().mode == "Mail")
    }

    @Test func mode_key_while_recording_leaves_the_dictation_and_its_mode_alone() async throws {
        let rig = SessionRig()
        try rig.modes.edit { book in
            try book.add(Mode(id: "mail", name: "Mail", promptID: Prompt.email.id))
            try book.setModes(for: "com.apple.TextEdit", ids: [Mode.dictation.id, "mail"], defaultID: Mode.dictation.id)
        }
        await rig.pressAndConfirm()

        rig.session.cycleMode()
        #expect(rig.session.notice == nil)
        rig.release()
        await rig.session.shutdown()

        #expect(try await rig.onlyEntry().mode == Mode.dictation.name)
    }

    @Test func cleanup_switched_off_in_settings_beats_a_mode_that_has_it_on() async throws {
        let engine = FakeCleanupEngine { _ in "Hello from the test." }
        let rig = SessionRig(engine: engine)
        rig.settings.store.set(false, for: CleanupSettings.isEnabled)

        await rig.dictate()

        #expect(engine.calls.isEmpty)
        #expect(try await rig.onlyEntry().cleanup.reason == CleanupResult.Reason.switchedOff.rawValue)
    }
}
