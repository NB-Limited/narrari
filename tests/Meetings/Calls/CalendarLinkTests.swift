import Foundation
import NarrariKit
import Testing

struct CalendarLinkTests {
    private static let minute: TimeInterval = 60

    private func event(_ title: String, from start: TimeInterval, to end: TimeInterval, at time: Date, isAllDay: Bool = false) -> CalendarEvent {
        CalendarEvent(
            title: title, start: time.addingTimeInterval(start * Self.minute), end: time.addingTimeInterval(end * Self.minute),
            isAllDay: isAllDay, attendees: ["Ana Petrova"]
        )
    }

    // Now for a live meeting, the recording time for an imported file.
    @Test(arguments: [Date.now, Date(timeIntervalSince1970: 1_700_000_000)])
    func picks_the_event_under_way_or_starting_within_5_minutes(at time: Date) async {
        let holiday = event("Holiday", from: -600, to: 840, at: time, isAllDay: true)
        let review = event("Design review", from: -30, to: 30, at: time)
        let client = event("Client call", from: 3, to: 33, at: time)
        let later = event("Planning", from: 6, to: 36, at: time)
        let over = event("Standup", from: -16, to: -1, at: time)

        func found(in events: [CalendarEvent]) async -> String? {
            await CalendarLink(source: FakeCalendar(events: events), ownerName: "Mila Novak").event(at: time)?.title
        }

        #expect(await found(in: [holiday, review, later, over]) == "Design review")
        #expect(await found(in: [holiday, review, client]) == "Client call")
        #expect(await found(in: [holiday, later, over]) == nil)
    }

    @Test func the_owner_invited_under_a_directory_spelling_is_not_among_the_people() async {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CalendarEvent(
            title: "Review", start: time, end: time.addingTimeInterval(1800),
            attendees: ["Novak,Milena M.M.", "Novak", "Petrova,Ana A.", "Mira Kostova"]
        )

        let found = await CalendarLink(source: FakeCalendar(events: [event]), ownerName: "Mila Novak").event(at: time)

        #expect(found?.attendees == ["Novak", "Petrova,Ana A.", "Mira Kostova"])
    }
}
