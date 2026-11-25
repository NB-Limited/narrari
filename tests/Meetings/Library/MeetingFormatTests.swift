import Foundation
import NarrariKit
import Testing

struct MeetingFormatTests {
    @Test func a_saved_meeting_whose_invite_lists_the_owner_reads_them_only_as_you() {
        var meeting = Meeting(title: "Weekly", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        meeting.speakers = [
            Meeting.Speaker(id: MeetingTranscript.ownerID, name: "Mila Novak"), Meeting.Speaker(id: "speaker-2", name: "Ana Petrova")
        ]
        meeting.attendees = ["Novak,Milena M.M.", "Boris Ivanov"].map { Meeting.Attendee(name: $0, source: .calendar) }

        #expect(MeetingFormat.pagePeople(of: meeting) == "Ana Petrova, Boris Ivanov and you")
    }
}
