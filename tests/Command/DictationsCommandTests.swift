import Foundation
import NarrariKit
import Testing

@MainActor
struct DictationsCommandTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()

    @Test func search_prints_a_row_for_each_dictation_that_holds_the_text() async throws {
        let history = HistoryStore(root: folder.url)
        let context = Command.Context.throwaway(in: folder, settings: settings.store, history: history)
        let found = UUID()
        for (id, text) in [(found, "Send the quote to Müller today."), (UUID(), "Lunch at noon.")] {
            try await history.append(
                HistoryEntry(id: id, startedAt: Date(), durationMs: 4_000, finalText: text, audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted)
            )
        }

        let reply = try #require(await Command(arguments: ["dictations", "search", "muller"])?.run(in: context))
        let rows = reply.output.split(separator: "\n")

        #expect(reply.status == 0)
        #expect(rows.count == 2)
        #expect(rows[1].hasPrefix(found.uuidString) && rows[1].hasSuffix("Send the quote to Müller today."))
    }
}
