import Foundation
import NarrariKit
import Testing

struct EntryNotesTests {
    private func entry(heard: String, final: String, status: CleanupResult.Status, reason: CleanupResult.Reason? = nil) -> HistoryEntry {
        let id = UUID()
        var entry = HistoryEntry(id: id, startedAt: Date(), rawText: heard, finalText: final, audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted)
        entry.cleanup.status = status.rawValue
        entry.cleanup.reason = reason?.rawValue ?? ""
        return entry
    }

    @Test func what_clean_up_removed_shows_only_when_clean_up_changed_a_word() {
        let cleaned = entry(heard: "so um send it today", final: "So send it today.", status: .cleaned)
        let replacedWithCleanupOff = entry(heard: "send it to art ie", final: "send it to Arty", status: .off, reason: .switchedOff)
        let skipped = entry(heard: "send it today", final: "send it today ok", status: .skipped, reason: .timedOut)
        let onlyPunctuation = entry(heard: "send it today", final: "Send it today.", status: .cleaned)

        #expect(cleaned.cleanupEdits?.contains(TextDiff.Segment(.removed, "um")) == true)
        #expect(replacedWithCleanupOff.cleanupEdits == nil)
        #expect(skipped.cleanupEdits == nil)
        #expect(onlyPunctuation.cleanupEdits == nil)
    }

    @Test func made_with_says_when_clean_up_was_off() {
        var item = entry(heard: "hi there", final: "hi there", status: .off, reason: .skippedLanguage)
        item.speechModel = "Parakeet v3"

        #expect(item.madeWith(appName: "Slack") == "Parakeet v3. Clean-up off for this language. Pasted into Slack.")
    }
}
