import Foundation

public struct HistoryDay: Identifiable, Sendable, Equatable {
    public let id: Date
    public let title: String
    public let entries: [HistoryEntry]

    // Entries keep their order inside a day, so newest first in gives newest first out.
    public static func group(_ entries: [HistoryEntry], now: Date, calendar: Calendar = HistoryStore.localCalendar) -> [HistoryDay] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.startedAt) }
            .sorted { $0.key > $1.key }
            .map { HistoryDay(id: $0.key, title: title(for: $0.key, now: now, calendar: calendar), entries: $0.value) }
    }

    public static func title(for day: Date, now: Date, calendar: Calendar = HistoryStore.localCalendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) { style = style.year() }
        return day.formatted(style)
    }
}
