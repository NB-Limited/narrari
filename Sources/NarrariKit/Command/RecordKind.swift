import Foundation

// Meetings or dictations: what narrari meetings, narrari dictations and the connector's tools read. All of it read-only.
public enum RecordKind: String, Sendable, CaseIterable {
    case meetings
    case dictations

    var command: any RecordCommand.Type {
        switch self {
        case .meetings: MeetingsCommand.self
        case .dictations: DictationsCommand.self
        }
    }

    // What the window says when its list can't be read.
    var readFailed: Problem {
        switch self {
        case .meetings: MeetingLibrary.readFailed
        case .dictations: HistoryLibrary.readFailed
        }
    }

    // The line an AI tool with a terminal runs to read one meeting or dictation, as `show` reads it.
    public func showLine(_ id: UUID) -> String {
        "narrari \(rawValue) show \(id.uuidString)"
    }

    var singular: String {
        switch self {
        case .meetings: "meeting"
        case .dictations: "dictation"
        }
    }

    private static let dayFormat: Date.FormatString = "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)"
    private static let startFormat: Date.FormatString = """
        \(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) \
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
        """

    // The start of a day written as 2026-11-22, on this Mac's clock.
    static func day(_ text: String) -> Date? {
        let calendar = HistoryStore.localCalendar
        let strategy = Date.ParseStrategy(
            format: dayFormat, locale: Locale(identifier: "en_US_POSIX"), timeZone: calendar.timeZone, calendar: calendar, isLenient: false
        )
        return (try? Date(text, strategy: strategy)).map(calendar.startOfDay(for:))
    }

    static func started(_ date: Date) -> String {
        let calendar = HistoryStore.localCalendar
        return date.formatted(
            Date.VerbatimFormatStyle(format: startFormat, locale: Locale(identifier: "en_US_POSIX"), timeZone: calendar.timeZone, calendar: calendar)
        )
    }

    // Columns padded to their widest cell, the last one left as it is; a cell never breaks its row.
    static func table(_ head: [String], _ rows: [[String]]) -> String {
        let lines = ([head] + rows).map { $0.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") } }
        let widths = head.indices.dropLast().map { column in lines.map { $0[column].count }.max() ?? 0 }
        return lines.map { cells in
            (zip(cells, widths).map { $0.padded(to: $1) } + [cells.last ?? ""]).joined(separator: "  ")
        }
        .joined(separator: "\n") + "\n"
    }
}

@MainActor
protocol RecordCommand {
    static func list(since: Date?, limit: Int?, asJSON: Bool, in context: Command.Context) async throws -> String
    static func search(_ text: String, limit: Int?, in context: Command.Context) async throws -> String
    // Nil when no record has the id.
    static func read(_ id: UUID, part: MeetingPart?, in context: Command.Context) async throws -> String?
}
