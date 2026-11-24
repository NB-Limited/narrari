import Foundation

public struct CalendarEvent: Sendable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    // The other people invited, by name; never the owner.
    public let attendees: [String]

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, attendees: [String]) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
    }
}

// Without calendar access a source gives no events: no error and no prompt.
public protocol CalendarSource: Sendable {
    func events(from start: Date, to end: Date) async -> [CalendarEvent]
}

// The event a meeting belongs to: under way at the time, or starting within 5 minutes of it.
public struct CalendarLink: Sendable {
    private static let lead: TimeInterval = 5 * 60

    private let source: any CalendarSource

    public init(source: any CalendarSource) {
        self.source = source
    }

    // Of several, the one that starts nearest the time, so a call opened early for the next event is not given the last one.
    public func event(at time: Date) async -> CalendarEvent? {
        await source.events(from: time, to: time.addingTimeInterval(Self.lead))
            .filter { !$0.isAllDay && $0.end > time && $0.start <= time.addingTimeInterval(Self.lead) }
            .min { abs($0.start.timeIntervalSince(time)) < abs($1.start.timeIntervalSince(time)) }
    }
}
