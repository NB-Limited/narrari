import Foundation
import NarrariKit
import Testing

@MainActor
struct ModesPageModelTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    private func page() -> ModesPageModel {
        let page = ModesPageModel(store: ModeStore(root: folder.url), prompts: PromptStore(root: folder.url), settings: settings.mirror, apps: AppDirectory())
        page.appear()
        return page
    }

    @Test func mode_name_already_taken_is_refused() throws {
        let page = page()
        page.startAdding()
        page.draft?.name = " dictation "

        page.commit()

        #expect(page.nameError == "Another mode is called dictation. Use another name.")
        #expect(try ModeStore(root: folder.url).load().modes == [.dictation])
    }

    @Test func global_default_offers_no_delete() {
        let page = page()

        page.requestDeletion(Mode.dictation.id)

        #expect(!page.canDelete(Mode.dictation.id))
        #expect(page.pendingDeletion == nil)
    }

    @Test func adding_a_mode_never_writes_over_an_unreadable_file() throws {
        let file = folder.url.appending(path: "modes.json")
        let unreadable = Data(#"{"modes":[{"id":"dictation","name":"Dictation"},{"id":"mail","name":"Mail""#.utf8)
        try unreadable.write(to: file)
        let page = page()
        #expect(page.file.isUnreadable)

        page.startAdding()
        page.draft?.name = "Chat"
        page.commit()

        let after = try Data(contentsOf: file)
        #expect(after == unreadable)
    }

    @Test func start_fresh_keeps_the_unreadable_file_and_lets_edits_save() throws {
        let file = folder.url.appending(path: "modes.json")
        let unreadable = Data(#"{"modes":[{"id":"mail""#.utf8)
        try unreadable.write(to: file)
        let page = page()

        page.startFresh()
        page.startAdding()
        page.draft?.name = "Chat"
        page.commit()

        #expect(!page.file.isUnreadable)
        let kept = try FileManager.default.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("modes.unreadable-") }
        #expect(try kept.map { try Data(contentsOf: $0) } == [unreadable])
        #expect(try ModeStore(root: folder.url).load().modes.map(\.name) == ["Dictation", "Chat"])
    }
}
