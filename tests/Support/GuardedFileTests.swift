import Foundation
import NarrariKit
import Testing

@MainActor
struct GuardedFileTests {
    private let folder = TemporaryFolder()

    @Test func start_fresh_renames_the_file_beside_itself_with_the_time() throws {
        let url = folder.url.appending(path: "prompts.json")
        let unreadable = Data(#"[{"id":"standup""#.utf8)
        try unreadable.write(to: url)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .autoupdatingCurrent
        let now = try #require(local.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9, minute: 5, second: 7)))
        let file = GuardedFile(url: url, now: { now })

        file.startFresh()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        let aside = folder.url.appending(path: "prompts.unreadable-20261119-090507.json")
        #expect(try Data(contentsOf: aside) == unreadable)
        #expect(file.moveError == nil)
    }

    @Test func start_fresh_that_cannot_rename_says_why() {
        let file = GuardedFile(url: folder.url.appending(path: "missing.json"))

        file.startFresh()

        #expect(file.moveError == "missing.json could not be renamed. Move it out of the folder in Finder, then open this page again.")
    }
}
