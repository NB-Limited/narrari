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
    private let owner: OwnerName

    public init(source: any CalendarSource, ownerName: String) {
        self.source = source
        owner = OwnerName(ownerName)
    }

    // Of several, the one that starts nearest the time, so a call opened early for the next event is not given the last one.
    // A calendar that does not know the invite is the owner's lists them among the people; they are left out here.
    public func event(at time: Date) async -> CalendarEvent? {
        let event = await source.events(from: time, to: time.addingTimeInterval(Self.lead))
            .filter { !$0.isAllDay && $0.end > time && $0.start <= time.addingTimeInterval(Self.lead) }
            .min { abs($0.start.timeIntervalSince(time)) < abs($1.start.timeIntervalSince(time)) }
        return event.map {
            CalendarEvent(title: $0.title, start: $0.start, end: $0.end, isAllDay: $0.isAllDay, attendees: $0.attendees.filter { !owner.matches($0) })
        }
    }
}
