import Foundation

// The rows a speaker's name opens: who it might be, merges, and "Not this person" on a name the app set.
public enum SpeakerMenu {
    public enum Action: Sendable, Equatable {
        case person(UUID)
        case name(String)
        case merge(into: String)
        case notThisPerson
    }

    public struct Row: Sendable, Equatable {
        public let title: String
        public var detail: String?
        public var group: String?
        public var startsSection = false
        public var isChecked = false
        public let action: Action
    }

    public static func rows(for speaker: Meeting.Speaker, in meeting: Meeting, people: [VoiceMemory.Person], query: String) -> [Row] {
        var rows: [Row] = []
        var named: Set<String> = []
        func offer(_ row: Row) {
            guard named.insert(row.title.lowercased()).inserted else { return }
            rows.append(row)
        }
        let isSetByApp = speaker.isNamedByUser != true && (speaker.personId != nil || speaker.isGuess == true)
        if isSetByApp {
            let action = speaker.personId.map(Action.person) ?? .name(speaker.name)
            offer(Row(title: speaker.name, detail: speaker.isGuess == true ? "Guess" : "Voice match", isChecked: true, action: action))
        } else if !MeetingFormat.isNumbered(speaker) {
            named.insert(speaker.name.lowercased())
        }
        if let suggested = people.first(where: { $0.id == speaker.suggestion }) {
            offer(Row(title: suggested.name, detail: "Close match", group: "Sounds like", action: .person(suggested.id)))
        }
        let invited = meeting.attendees.map(\.name)
        for (index, name) in invited.enumerated() {
            offer(Row(title: name, group: index == 0 ? "Invited" : nil, action: .name(name)))
        }
        let known = people.filter { !$0.isOwner && !named.contains($0.name.lowercased()) }
        for (index, person) in known.enumerated() {
            offer(Row(title: person.name, group: index == 0 ? "People you named" : nil, action: .person(person.id)))
        }
        // Merging everyone on the call's sound into the owner is lost once speakers are found, so it is not offered.
        let others = meeting.speakers.filter { other in
            other.id != speaker.id && (other.id != MeetingTranscript.ownerID || speaker.id != MeetingTranscript.othersID)
        }
        for (index, other) in others.enumerated() {
            rows.append(Row(title: "Merge into \(MeetingPage.name(of: other))", startsSection: index == 0, action: .merge(into: other.id)))
        }
        if isSetByApp {
            rows.append(Row(title: "Not this person", startsSection: true, action: .notThisPerson))
        }
        return filtered(rows, by: query)
    }

    // Typing keeps the rows whose name holds it, without heads or rules, and offers it as a new person.
    private static func filtered(_ rows: [Row], by query: String) -> [Row] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        var kept = rows.filter { MeetingSearch.contains($0.title, query) }.map { row in
            Row(title: row.title, detail: row.detail, isChecked: row.isChecked, action: row.action)
        }
        if !kept.contains(where: { $0.title.caseInsensitiveCompare(query) == .orderedSame }) {
            kept.append(Row(title: "Add “\(query)” as a new person", action: .name(query)))
        }
        return kept
    }
}
