import Foundation
import NarrariKit
import Testing

struct SpeakerMenuTests {
    private let lena = person("Lena Fischer")
    private let tomas = person("Tomas Novak")
    private let maria = person("Maria Petrova")

    private var meeting: Meeting {
        var meeting = Meeting(title: "Delivery plan", startedAt: .now, app: "", source: .call, template: "general", state: .ready)
        meeting.attendees = [.init(name: "Jonas Weber", source: .calendar), .init(name: "Lena Fischer", source: .callWindow)]
        meeting.speakers = [
            .init(id: "owner", name: "Mila Novak"),
            .init(id: "speaker-2", name: "Maria Petrova", personId: maria.id),
            .init(id: "speaker-3", name: "Speaker 3", suggestion: lena.id)
        ]
        return meeting
    }

    private func titles(_ speaker: Int, typed: String = "") -> [String] {
        SpeakerMenu.rows(for: meeting.speakers[speaker], in: meeting, people: [lena, tomas, maria], query: typed).map(\.title)
    }

    @Test func a_close_voice_comes_first_then_who_was_invited_and_named_then_merges() {
        #expect(titles(2) == ["Lena Fischer", "Jonas Weber", "Tomas Novak", "Maria Petrova", "Merge into You", "Merge into Maria Petrova"])
        #expect(SpeakerMenu.rows(for: meeting.speakers[2], in: meeting, people: [lena], query: "").first?.detail == "Close match")
    }

    @Test func a_name_the_app_set_is_checked_and_can_be_taken_back() {
        let rows = SpeakerMenu.rows(for: meeting.speakers[1], in: meeting, people: [lena, tomas, maria], query: "")
        #expect(rows.first?.isChecked == true && rows.first?.detail == "Voice match")
        #expect(rows.last?.action == .notThisPerson)
    }

    @Test func everyone_on_the_calls_sound_before_the_split_is_not_offered_to_merge_into_you() {
        var meeting = meeting
        meeting.speakers = [.init(id: "owner", name: "Mila Novak"), .init(id: "others", name: "Speaker 2")]
        let rows = SpeakerMenu.rows(for: meeting.speakers[1], in: meeting, people: [], query: "")
        #expect(!rows.contains { $0.action == .merge(into: "owner") })
    }

    @Test func typing_filters_every_row_and_offers_a_new_person() {
        #expect(titles(2, typed: "le") == ["Lena Fischer", "Add “le” as a new person"])
        #expect(titles(2, typed: "lena fischer") == ["Lena Fischer"])
    }
}

// As people.json holds them.
private func person(_ name: String) -> VoiceMemory.Person {
    let json = #"{"id":"\#(UUID().uuidString)","name":"\#(name)","isOwner":false,"prints":[]}"#
    return try! JSONDecoder().decode(VoiceMemory.Person.self, from: Data(json.utf8))
}
