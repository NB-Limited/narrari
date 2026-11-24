import Foundation

public enum MeetingPart: String, CaseIterable, Sendable {
    case summary
    case notes
    case transcript
}

enum MeetingsCommand: RecordCommand {
    static func list(since: Date?, limit: Int?, asJSON: Bool, in context: Command.Context) async throws -> String {
        let meetings = Array(try await context.meetings.meetings(since: since).meetings.prefix(limit ?? .max))
        return asJSON ? try json(meetings) : rows(meetings)
    }

    static func search(_ text: String, limit: Int?, in context: Command.Context) async throws -> String {
        rows(Array(try await MeetingSearch.meetings(matching: text, in: context.meetings).prefix(limit ?? .max)))
    }

    static func read(_ id: UUID, part: MeetingPart?, in context: Command.Context) async throws -> String? {
        let store = context.meetings
        let meeting: Meeting
        do {
            meeting = try await store.meeting(id)
        } catch MeetingError.notFound {
            return nil
        }
        if let part {
            let text = try await self.text(part, of: meeting, in: store)
            return text.isEmpty ? "This meeting has no \(part.rawValue).\n" : text
        }
        var sections = [header(meeting)]
        for part in MeetingPart.allCases {
            let text = try await self.text(part, of: meeting, in: store)
            if !text.isEmpty { sections.append("## \(part.rawValue.capitalized)\n\n\(text)") }
        }
        return sections.joined(separator: "\n")
    }

    private static func text(_ part: MeetingPart, of meeting: Meeting, in store: MeetingStore) async throws -> String {
        let text = switch part {
        case .summary: try await store.text(.summary, of: meeting.id)
        case .notes: try await store.text(.notes, of: meeting.id)
        case .transcript: TranscriptSegment.markdown(try await store.transcript(of: meeting.id), speakers: meeting.speakers)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }

    private static func header(_ meeting: Meeting) -> String {
        var lines = ["# \(title(meeting))", "\(RecordKind.started(meeting.startedAt)), \(length(meeting))"]
        if !meeting.attendees.isEmpty { lines.append("Attendees: " + meeting.attendees.map(\.name).joined(separator: ", ")) }
        if !meeting.speakers.isEmpty { lines.append("Speakers: " + meeting.speakers.map(\.name).joined(separator: ", ")) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func rows(_ meetings: [Meeting]) -> String {
        guard !meetings.isEmpty else { return "No meetings.\n" }
        return RecordKind.table(
            ["ID", "STARTED", "LENGTH", "TITLE"],
            meetings.map { [$0.id.uuidString, RecordKind.started($0.startedAt), length($0), title($0)] }
        )
    }

    // As meeting.json holds them.
    private static func json(_ meetings: [Meeting]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (String(bytes: try encoder.encode(meetings.map { try $0.fields }), encoding: .utf8) ?? "") + "\n"
    }

    private static func title(_ meeting: Meeting) -> String {
        meeting.title.isEmpty ? "Untitled meeting" : meeting.title
    }

    private static func length(_ meeting: Meeting) -> String {
        Duration.milliseconds(meeting.durationMs).formatted(.time(pattern: .hourMinuteSecond))
    }
}
