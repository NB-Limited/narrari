import Foundation
import NarrariKit
import Testing

struct SummaryTemplateFolderTests {
    private let folder = TemporaryFolder()

    private var templates: URL { folder.url.appending(path: "Templates") }

    private func text(_ id: String) throws -> String {
        try String(contentsOf: templates.appending(path: id + ".md"), encoding: .utf8)
    }

    @Test func first_use_copies_the_built_ins_and_lists_them_with_the_users_own_files() throws {
        let shipped = SummaryTemplateFolder(url: templates, builtIns: SummaryTemplateFolder.bundled)
        _ = try shipped.all()
        try "Standup\n\n## Blockers\nWhat stops each person, one bullet each.\n".write(
            to: templates.appending(path: "standup.md"), atomically: true, encoding: .utf8
        )
        try "Notes without headings\n".write(to: templates.appending(path: "broken.md"), atomically: true, encoding: .utf8)

        let all = try shipped.all()

        #expect(all.map(\.name) == ["Client call", "General meeting", "One-to-one", "Standup"])
        #expect(try shipped.template("general").sections.map(\.heading) == ["Overview", "Decisions", "Action items", "Open questions"])
        let own = try shipped.template("standup").sections
        #expect(own.map(\.heading) == ["Blockers"] && own.map(\.instruction) == ["What stops each person, one bullet each."])
    }

    @Test func a_built_in_never_edited_takes_the_newer_text_and_an_edited_one_is_kept() throws {
        let first = ["general": "General\n## Overview\nWhat it was about.\n", "one-to-one": "One-to-one\n## Overview\nWhat they said.\n"]
        let newer = ["general": "General\n## Overview\nWhat it was about, briefly.\n", "one-to-one": "One-to-one\n## Overview\nWhat both said.\n"]
        _ = try SummaryTemplateFolder(url: templates, builtIns: first).all()
        let edited = "One-to-one\n## Overview\nWhat they said.\n## Mood\nHow the talk felt.\n"
        try edited.write(to: templates.appending(path: "one-to-one.md"), atomically: true, encoding: .utf8)

        _ = try SummaryTemplateFolder(url: templates, builtIns: newer).all()

        #expect(try text("general") == newer["general"])
        #expect(try text("one-to-one") == edited)
    }

    @Test func a_meeting_whose_template_was_deleted_uses_the_default_then_general_meeting() throws {
        let shipped = SummaryTemplateFolder(url: templates, builtIns: SummaryTemplateFolder.bundled)

        let toDefault = try shipped.template("standup", orElse: "one-to-one")
        let toGeneral = try shipped.template("standup", orElse: "weekly")

        #expect(toDefault.name == "One-to-one")
        #expect(toGeneral.name == "General meeting")
    }
}
