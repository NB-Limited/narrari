import Foundation
import NarrariKit
import Testing

@MainActor
struct SummariesPageModelTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    private var templates: SummaryTemplateFolder {
        SummaryTemplateFolder(url: folder.url.appending(path: "Templates"), builtIns: SummaryTemplateFolder.bundled)
    }

    private func page() -> SummariesPageModel {
        SummariesPageModel(
            folder: templates, settings: settings.mirror, summaryModels: SummaryModels(settings: settings.store, store: ModelStore(root: folder.url))
        )
    }

    @Test func a_file_written_by_hand_shows_on_the_next_read_beside_the_built_ins() throws {
        let model = page()
        model.appear()
        try "Standup\n\n## Blockers\nWhat stops each person.\n## Next\nWhat each does next.\n".write(
            to: templates.url.appending(path: "standup.md"), atomically: true, encoding: .utf8
        )

        model.appear()

        #expect(model.builtIn.map(\.name) == ["Client call", "General meeting", "One-to-one"])
        #expect(model.yours.map(\.name) == ["Standup"])
        #expect(model.yours.first?.headings == "Blockers, Next")
        #expect(model.defaultID == "general")
    }

    @Test func a_copy_of_a_built_in_saves_as_a_plain_file_the_summary_reads_and_keeps_its_file_when_renamed() throws {
        let model = page()
        model.appear()
        model.startDuplicating("general")
        model.commit()
        let copy = try #require(model.yours.first)

        model.startEditing(copy.id)
        model.draft?.name = "Weekly"
        model.draft?.text = "## Overview\nWhat the week was about."
        model.commit()

        #expect(model.yours.map(\.name) == ["Weekly"])
        #expect(try templates.template(copy.id).sections.map(\.heading) == ["Overview"])
        let file = try String(contentsOf: templates.url.appending(path: copy.id + ".md"), encoding: .utf8)
        #expect(file == "Weekly\n\n## Overview\nWhat the week was about.\n")
    }

    @Test func text_without_a_heading_is_refused_and_nothing_is_written() throws {
        let model = page()
        model.appear()
        model.startAdding()
        model.draft?.name = "Notes"
        model.draft?.text = "Just write it all down."

        model.commit()

        #expect(model.textError != nil)
        #expect(model.draft != nil)
        #expect(try templates.all().map(\.name) == ["Client call", "General meeting", "One-to-one"])
    }

    @Test func deleting_the_default_removes_its_file_and_hands_the_default_back_to_general() throws {
        let model = page()
        model.appear()
        model.startAdding()
        model.draft?.name = "Standup"
        model.draft?.text = "## Blockers\nWhat stops each person."
        model.commit()
        let standup = try #require(model.yours.first)
        model.makeDefault(standup.id)
        #expect(settings.store.value(MeetingsSettings.summaryTemplate) == standup.id)

        model.requestDeletion(standup.id)
        model.confirmDeletion()

        #expect(model.yours.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: templates.url.appending(path: standup.id + ".md").path))
        #expect(settings.store.value(MeetingsSettings.summaryTemplate) == "general")
        #expect(model.defaultID == "general")
    }

    @Test func a_file_that_cannot_be_read_stays_listed_until_deleted() throws {
        let model = page()
        model.appear()
        try "Standup\n\nJust write it all down.\n".write(to: templates.url.appending(path: "standup.md"), atomically: true, encoding: .utf8)

        model.appear()
        let listed = model.unreadable
        model.requestDeletion("standup")
        model.confirmDeletion()

        #expect(listed == ["standup"])
        #expect(model.unreadable.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: templates.url.appending(path: "standup.md").path))
    }
}
