import Foundation
import NarrariKit
import Testing

struct EntryFormatTests {
    private let morning = try! Date("2026-11-19T09:30:00Z", strategy: .iso8601)

    private func entry(_ text: String, skipped: Bool = false) -> HistoryEntry {
        let id = UUID()
        var entry = HistoryEntry(
            id: id, startedAt: morning, durationMs: 2400, finalText: text, audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted
        )
        if skipped {
            entry.cleanup.status = CleanupResult.Status.skipped.rawValue
            entry.cleanup.reason = CleanupResult.Reason.timedOut.rawValue
        }
        return entry
    }

    @Test func when_names_the_day_before_the_time() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let item = entry("Hi.")
        let nextDay = morning.addingTimeInterval(24 * 60 * 60)

        #expect(EntryFormat.when(item, now: nextDay, calendar: utc) == "Yesterday, \(EntryFormat.time(item))")
    }

    @Test func age_counts_minutes_then_hours_and_leaves_other_days_to_the_day_name() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let item = entry("Hi.")

        #expect(EntryFormat.age(item, now: morning.addingTimeInterval(59), calendar: utc) == "just now")
        #expect(EntryFormat.age(item, now: morning.addingTimeInterval(2 * 60 + 30), calendar: utc) == "2 min ago")
        #expect(EntryFormat.age(item, now: morning.addingTimeInterval(3 * 60 * 60), calendar: utc) == "3 h ago")
        #expect(EntryFormat.age(item, now: morning.addingTimeInterval(24 * 60 * 60), calendar: utc) == nil)
    }

    @Test func spoken_summary_keeps_the_first_eight_words_and_a_skipped_clean_up() {
        let item = entry("Tell Ivan the report on the new office is late again", skipped: true)

        let summary = EntryFormat.spokenSummary(item, source: "Slack")

        #expect(summary == "Slack, \(EntryFormat.time(item)), Tell Ivan the report on the new office, Clean-up skipped")
    }

    @Test func spoken_summary_of_an_entry_without_text_says_what_happened() {
        var item = entry("")
        item.outcome = .failed

        #expect(EntryFormat.spokenSummary(item, source: "Mail") == "Mail, \(EntryFormat.time(item)), Not transcribed. The audio is kept.")
    }
}
