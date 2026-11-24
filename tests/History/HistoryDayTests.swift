import Foundation
import NarrariKit
import Testing

struct HistoryDayTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .gmt
        return calendar
    }()

    private func entry(_ time: String) throws -> HistoryEntry {
        let id = UUID()
        return HistoryEntry(id: id, startedAt: try Date(time, strategy: .iso8601), audioFile: HistoryEntry.audioFileName(for: id))
    }

    // A file being transcribed is listed first whatever its day, so entries don't always come newest first.
    @Test func entries_out_of_order_each_land_in_their_own_day_in_the_order_given() throws {
        let lateSunday = try entry("2026-10-25T22:30:00Z")
        let mondayFirst = try entry("2026-10-25T23:30:00Z")
        let saturday = try entry("2026-10-24T12:00:00Z")
        let mondayLater = try entry("2026-10-26T08:00:00Z")
        let now = try Date("2026-10-26T09:00:00Z", strategy: .iso8601)

        let days = HistoryDay.group([mondayFirst, lateSunday, saturday, mondayLater], now: now, calendar: calendar)

        let starts = try ["2026-10-25T23:00:00Z", "2026-10-24T22:00:00Z", "2026-10-23T22:00:00Z"].map { try Date($0, strategy: .iso8601) }
        #expect(days.map(\.id) == starts)
        #expect(days.prefix(2).map(\.title) == ["Today", "Yesterday"])
        #expect(days.map { $0.entries.map(\.id) } == [[mondayFirst.id, mondayLater.id], [lateSunday.id], [saturday.id]])
    }
}
