import Foundation

// How a history entry reads in the list, the reader and to VoiceOver.
public enum EntryFormat {
    // Where the text came from: the file's name, or the app it was dictated into.
    @MainActor public static func source(_ entry: HistoryEntry, apps: AppDirectory) -> String {
        entry.file ?? apps.name(for: entry.app)
    }

    public static func length(_ entry: HistoryEntry) -> String {
        Duration.milliseconds(entry.durationMs).formatted(.time(pattern: .minuteSecond))
    }

    public static func time(_ entry: HistoryEntry) -> String {
        entry.startedAt.formatted(date: .omitted, time: .shortened)
    }

    public static func when(_ entry: HistoryEntry, now: Date = Date(), calendar: Calendar = HistoryStore.localCalendar) -> String {
        "\(HistoryDay.title(for: entry.startedAt, now: now, calendar: calendar)), \(time(entry))"
    }

    // How long ago, within the same day; an older entry reads by its day instead, so this is nil.
    public static func age(_ entry: HistoryEntry, now: Date, calendar: Calendar = HistoryStore.localCalendar) -> String? {
        guard calendar.isDate(entry.startedAt, inSameDayAs: now) else { return nil }
        let minutes = Int(max(0, now.timeIntervalSince(entry.startedAt)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }

    public static func position(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: .minuteSecond))
    }

    // The app, the time and the first eight words, so a list row reads quickly.
    public static func spokenSummary(_ entry: HistoryEntry, source: String) -> String {
        let words = entry.finalText.split(separator: " ").prefix(8).joined(separator: " ")
        var parts = [source, time(entry), words.isEmpty ? (entry.outcomeNote ?? "No text") : words]
        if entry.isCleanupSkipped { parts.append("Clean-up skipped") }
        return parts.joined(separator: ", ")
    }
}
