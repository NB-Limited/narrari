import Foundation
import NarrariKit
import Testing

@MainActor
struct HistorySearchTests {
    private func entry(heard: String = "", shown: String = "", file: String? = nil) -> HistoryEntry {
        let id = UUID()
        var entry = HistoryEntry(id: id, startedAt: Date(), rawText: heard, finalText: shown, audioFile: HistoryEntry.audioFileName(for: id))
        entry.file = file
        return entry
    }

    @Test func text_heard_text_shown_and_file_name_are_searched_ignoring_case_and_accents() {
        let shown = entry(shown: "Café on Thursday.")
        let heard = entry(heard: "um the RÉSUMÉ draft", shown: "The draft.")
        let file = entry(file: "Interview Zoë.m4a")
        let other = entry(shown: "Lunch at noon.")
        let all = [shown, heard, file, other]

        #expect(HistorySearch.entries(all, matching: "cafe", apps: AppDirectory()) == [shown])
        #expect(HistorySearch.entries(all, matching: "resume", apps: AppDirectory()) == [heard])
        #expect(HistorySearch.entries(all, matching: "zoe", apps: AppDirectory()) == [file])
        #expect(HistorySearch.entries(all, matching: "  ", apps: AppDirectory()) == all)
    }
}
