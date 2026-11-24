import Foundation
import NarrariKit
import Testing

@MainActor
struct PromptsPageModelTests {
    private let folder = TemporaryFolder()

    private func page() -> PromptsPageModel {
        let page = PromptsPageModel(store: PromptStore(root: folder.url))
        page.appear()
        return page
    }

    @Test func trigger_phrase_already_in_use_names_the_prompt_that_has_it() throws {
        let page = page()
        page.startAdding()
        page.draft?.name = "Formal mail"
        page.draft?.instruction = "Write a formal email."
        page.draft?.triggers = "formal, Write email!"

        page.commit()

        #expect(page.triggerError == "“Write email!” is already a trigger phrase of Email. Use another phrase.")
        #expect(page.yours.isEmpty)
        #expect(try PromptStore(root: folder.url).load().isEmpty)
    }

    @Test func a_built_in_prompt_is_duplicated_into_one_of_yours_without_its_trigger_phrases() throws {
        let page = page()

        page.startDuplicating(Prompt.email.id)
        page.commit()

        let copy = try #require(page.yours.first)
        #expect(copy.name == "Email copy")
        #expect(copy.instruction == Prompt.email.instruction)
        #expect(copy.triggers.isEmpty)
        #expect(copy.id != Prompt.email.id)
        #expect(try PromptStore(root: folder.url).load() == [copy])
    }

    @Test func adding_a_prompt_never_writes_over_an_unreadable_file() throws {
        let file = folder.url.appending(path: "prompts.json")
        let unreadable = Data(#"[{"id":"standup","name":"Standup","instruction":"Notes.","triggers":[],"capsReplyLength":false},"#.utf8)
        try unreadable.write(to: file)
        let page = page()
        #expect(page.file.isUnreadable)

        page.startAdding()
        page.draft?.name = "Formal mail"
        page.draft?.instruction = "Write a formal email."
        page.commit()

        let after = try Data(contentsOf: file)
        #expect(after == unreadable)
    }
}
