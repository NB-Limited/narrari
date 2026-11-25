import Foundation
import NarrariKit
import Testing

struct RowMenuTests {
    private let meeting = Meeting(title: "Delivery plan", startedAt: .now, app: "", source: .call, template: "general", state: .ready)

    private func shown(_ rows: [RowMenu.Row]) -> [String] {
        rows.map { ($0.startsSection ? "| " : "") + $0.title }
    }

    @Test func a_meeting_offers_its_copies_then_pin_and_folder_then_delete() {
        let rows = RowMenu.meeting(meeting, summary: "Overview", transcript: "You: Hello.", isRecording: false)

        #expect(shown(rows) == [
            "Copy for an agent", "Copy summary", "Copy transcript",
            "| Pin and keep its audio", "Move to folder", "| Delete meeting"
        ])
        #expect(rows.first?.action == .copy(RecordKind.meetings.showLine(meeting.id)))
        #expect(rows[1].action == .copy("Overview") && rows[2].action == .copy("You: Hello."))
    }

    @Test func a_pinned_meeting_with_nothing_written_yet_offers_unpin_and_no_empty_copy() {
        var pinned = meeting
        pinned.pinned = true

        let rows = RowMenu.meeting(pinned, summary: "", transcript: "", isRecording: false)

        #expect(shown(rows) == ["Copy for an agent", "| Unpin", "Move to folder", "| Delete meeting"])
    }

    @Test func the_meeting_recording_offers_only_its_copies() {
        #expect(shown(RowMenu.meeting(meeting, summary: "", transcript: "You: Hello.", isRecording: true)) == [
            "Copy for an agent", "Copy transcript"
        ])
    }

    @Test func a_dictation_that_cannot_be_deleted_offers_its_copies_alone() {
        let entry = HistoryEntry(id: UUID(), startedAt: .now, finalText: "Send the draft today.", audioFile: "", outcome: .pasted)

        #expect(shown(RowMenu.dictation(entry, canDelete: true)) == ["Copy for an agent", "Copy text", "| Delete dictation"])
        #expect(shown(RowMenu.dictation(entry, canDelete: false)) == ["Copy for an agent", "Copy text"])
        #expect(RowMenu.dictation(entry, canDelete: false).first?.action == .copy(RecordKind.dictations.showLine(entry.id)))
    }

    @Test func a_dictation_still_being_made_is_not_offered_to_an_agent() {
        let entry = HistoryEntry(id: UUID(), startedAt: .now, audioFile: "")

        #expect(shown(RowMenu.dictation(entry, canDelete: true)) == ["Delete dictation"])
    }
}
