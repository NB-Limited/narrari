import EventKit
import Foundation

// The Mac's calendars, read only with full access; this never asks for it, the Permissions page does.
public actor EventKitCalendar: CalendarSource {
    // Made once access is given: a store made before the grant may not see the events.
    private var store: EKEventStore?

    public init() {}

    public func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = self.store ?? EKEventStore()
        self.store = store
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        return found.map { event in
            CalendarEvent(
                title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                attendees: Self.people(of: event)
            )
        }
    }

    // Some calendars leave the organiser out of the attendees, so they are read too, first, and once.
    private static func people(of event: EKEvent) -> [String] {
        let invited = ([event.organizer].compactMap { $0 } + (event.attendees ?? [])).filter(isOtherPerson).compactMap(\.name)
        return invited.reduce(into: []) { names, name in
            if !names.contains(name) { names.append(name) }
        }
    }

    private static func isOtherPerson(_ participant: EKParticipant) -> Bool {
        !participant.isCurrentUser && [.person, .unknown].contains(participant.participantType)
    }
}
