import Foundation
import NarrariKit
import Testing

struct TextPipelineTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    private func pipeline(_ engine: FakeCleanupEngine) throws -> TextPipeline {
        let dictionary = DictionaryStore(root: folder.url)
        try dictionary.edit { $0 = WordList(words: ["Narrari"], replacements: [Replacement(phrase: "nb limited", text: "NB Limited")]) }
        return TextPipeline(
            cleanup: CleanupService(engine: engine, settings: settings.store, clock: TestClock()),
            prompts: PromptStore(root: folder.url), dictionary: dictionary, settings: settings.store
        )
    }

    @Test func runs_the_trigger_then_cleanup_then_replacements() async throws {
        let engine = FakeCleanupEngine { _ in "Hi Anna, from nb limited." }

        let result = try await pipeline(engine).run("Write email hi anna from nb limited", prompt: .tidy, cleanup: .on)

        let call = try #require(engine.calls.first)
        #expect(call.transcript == "Hi anna from nb limited")
        #expect(call.instruction.contains(Prompt.email.instruction))
        #expect(call.instruction.contains("Spell these words exactly as written here: Narrari."))
        #expect(result.isTriggered)
        #expect(result.rawText == "Write email hi anna from nb limited")
        #expect(result.finalText == "Hi Anna, from NB Limited.")
    }

    @Test func triggers_switched_off_leave_the_text_and_the_mode_prompt_alone() async throws {
        settings.store.set(false, for: CleanupSettings.usesTriggers)
        let engine = FakeCleanupEngine { $0 }

        let result = try await pipeline(engine).run("Write email hi anna", prompt: .tidy, cleanup: .on)

        #expect(engine.calls.first?.transcript == "Write email hi anna")
        #expect(engine.calls.first?.instruction.contains(Prompt.tidy.instruction) == true)
        #expect(!result.isTriggered)
    }

    @Test func cleanup_off_still_removes_the_trigger_and_applies_replacements() async throws {
        let engine = FakeCleanupEngine { _ in "never asked" }

        let result = try await pipeline(engine).run("write email thanks from nb limited", prompt: .tidy, cleanup: .off(.switchedOff))

        #expect(engine.calls.isEmpty)
        #expect(result.cleanup.status == .off)
        #expect(result.finalText == "thanks from NB Limited")
    }

    @Test func trigger_alone_leaves_nothing_to_clean() async throws {
        let engine = FakeCleanupEngine { _ in "never asked" }

        let result = try await pipeline(engine).run("Write email.", prompt: .tidy, cleanup: .on)

        #expect(engine.calls.isEmpty)
        #expect(result.cleanup.reason == .nothingToClean)
        #expect(result.finalText.isEmpty)
    }

    @Test func spoken_marks_switched_off_change_nothing_and_switched_on_write_the_marks() async throws {
        let heard = "Hi team, new line, the build is green.\nAs an outside service may write it."
        func run(_ cleanup: CleanupSwitch) async throws -> (final: String, cleaned: [String]) {
            let engine = FakeCleanupEngine { $0 }
            let result = try await pipeline(engine).run(heard, prompt: .tidy, cleanup: cleanup)
            return (result.finalText, engine.calls.map(\.transcript))
        }

        let offWithCleanup = try await run(.on)
        let offWithoutCleanup = try await run(.off(.switchedOff))
        settings.store.set(true, for: DictionarySettings.writesSpokenMarks)
        let onWithoutCleanup = try await run(.off(.switchedOff))

        #expect(offWithCleanup.cleaned == [heard])
        #expect(offWithCleanup.final == heard)
        #expect(offWithoutCleanup.final == heard)
        #expect(onWithoutCleanup.final == "Hi team\nThe build is green.\nAs an outside service may write it.")
    }

    @Test func tidy_cleans_each_paragraph_on_its_own_and_a_rewriting_prompt_gets_the_whole_text() async throws {
        settings.store.set(true, for: DictionarySettings.writesSpokenMarks)
        let heard = "Dear Anna. New paragraph. Thanks for the letter. New line."
        let tidy = FakeCleanupEngine { $0.uppercased() }
        let email = FakeCleanupEngine { $0 }

        let tidied = try await pipeline(tidy).run(heard, prompt: .tidy, cleanup: .on)
        _ = try await pipeline(email).run(heard, prompt: .email, cleanup: .on)
        let breakAlone = try await pipeline(email).run("New line.", prompt: .email, cleanup: .on)

        #expect(tidy.calls.map(\.transcript) == ["Dear Anna", "Thanks for the letter"])
        #expect(tidied.finalText == "DEAR ANNA\n\nTHANKS FOR THE LETTER\n")
        #expect(email.calls.map(\.transcript) == ["Dear Anna\n\nThanks for the letter\n"])
        #expect(breakAlone.finalText == "\n")
    }

    private static let sentence = "Изпрати фактурата на Мария до петък, моля."

    @Test func dictation_in_a_skipped_language_is_pasted_as_spoken_without_asking_the_model() async throws {
        settings.store.set(["bg"], for: CleanupSettings.skippedLanguages)
        let engine = FakeCleanupEngine { _ in "never asked" }

        let result = try await pipeline(engine).run(Self.sentence, prompt: .tidy, cleanup: .on)

        #expect(engine.calls.isEmpty)
        #expect(result.cleanup.status == .off)
        #expect(result.cleanup.reason == .skippedLanguage)
        #expect(result.finalText == Self.sentence)
    }

    @Test func no_skipped_language_cleans_every_language() async throws {
        let engine = FakeCleanupEngine { $0 }

        _ = try await pipeline(engine).run(Self.sentence, prompt: .tidy, cleanup: .on)

        #expect(engine.calls.count == 1)
    }

    @Test func text_too_short_to_be_sure_of_its_language_is_cleaned() async throws {
        settings.store.set(["en"], for: CleanupSettings.skippedLanguages)
        let engine = FakeCleanupEngine { $0 }

        let result = try await pipeline(engine).run("Thanks, Anna.", prompt: .tidy, cleanup: .on)

        #expect(engine.calls.count == 1)
        #expect(result.cleanup.status == .cleaned)
    }

    @Test func unreadable_prompts_file_still_matches_the_built_in_triggers() async throws {
        try Data("{ not json".utf8).write(to: folder.url.appending(path: "prompts.json"))
        let engine = FakeCleanupEngine { $0 }

        let result = try await pipeline(engine).run("write email see you friday", prompt: .tidy, cleanup: .on)

        #expect(result.prompt == .email)
        #expect(try String(contentsOf: folder.url.appending(path: "prompts.json"), encoding: .utf8) == "{ not json")
    }
}
