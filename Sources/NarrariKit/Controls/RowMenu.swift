import Foundation

// What a right-click on a row in the window's lists offers, in the words of the page's own buttons. A row that cannot
// apply is left out, because the dropdown list has no disabled row.
public enum RowMenu {
    public enum Action: Sendable, Equatable {
        case copy(String)
        case togglePin
        case moveToFolder
        case delete
    }

    public struct Row: Sendable, Equatable {
        public let title: String
        public var startsSection = false
        public let action: Action
    }

    // A meeting while it records offers only the copies, as its page's toolbar offers only the recording's buttons.
    public static func meeting(_ meeting: Meeting, summary: String, transcript: String, isRecording: Bool) -> [Row] {
        let copies: [Row?] = [
            Row(title: "Copy for an agent", action: .copy(RecordKind.meetings.showLine(meeting.id))),
            summary.isEmpty ? nil : Row(title: "Copy summary", action: .copy(summary)),
            transcript.isEmpty ? nil : Row(title: "Copy transcript", action: .copy(transcript))
        ]
        guard !isRecording else { return sections(copies) }
        return sections(
            copies,
            [
                Row(title: meeting.pinned ? "Unpin" : "Pin and keep its audio", action: .togglePin),
                Row(title: "Move to folder", action: .moveToFolder)
            ],
            [Row(title: "Delete meeting", action: .delete)]
        )
    }

    // `dictations show` reads finished dictations only, so one still being made is not offered to an agent.
    public static func dictation(_ entry: HistoryEntry, canDelete: Bool) -> [Row] {
        sections(
            [
                entry.isFinished ? Row(title: "Copy for an agent", action: .copy(RecordKind.dictations.showLine(entry.id))) : nil,
                entry.finalText.isEmpty ? nil : Row(title: "Copy text", action: .copy(entry.finalText))
            ],
            [canDelete ? Row(title: "Delete dictation", action: .delete) : nil]
        )
    }

    private static func sections(_ sections: [Row?]...) -> [Row] {
        var rows: [Row] = []
        for section in sections {
            for (index, row) in section.compactMap(\.self).enumerated() {
                var row = row
                row.startsSection = index == 0 && !rows.isEmpty
                rows.append(row)
            }
        }
        return rows
    }
}
