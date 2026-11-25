import NarrariKit
import Testing

struct PersonNameTests {
    @Test(arguments: [
        ("Novak,Milena M.M.", "Milena Novak"), ("Berg, Stijn S.M.J. van den", "Stijn van den Berg"), ("Petrova, Ana", "Ana Petrova"),
        ("Ana Petrova", "Ana Petrova"), ("Vera Kostova (Acme)", "Vera Kostova (Acme)"), ("Acme, Inc.", "Acme, Inc."), ("Novak, M.", "Novak, M.")
    ])
    func a_name_listed_surname_first_reads_given_name_first_and_any_other_is_left(listed: String, plain: String) {
        #expect(PersonName.plain(listed) == plain)
    }

    @Test func a_meeting_keeps_one_spelling_of_a_person_invited_two_ways() {
        var meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        meeting.attendees = [Meeting.Attendee(name: "Novak,Milena M.M.", source: .calendar)]
        meeting.speakers = [Meeting.Speaker(id: "speaker-2", name: "Petrova,Ana A.")]

        #expect(meeting.attendees.map(\.name) == ["Milena Novak"] && meeting.speakers.map(\.name) == ["Ana Petrova"])
    }
}
