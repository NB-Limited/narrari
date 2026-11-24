import Foundation

// A line in the menu panel about work it did not show while it ran: a failed meeting, a summary ready, a file transcribed.
public struct MenuNote: Identifiable, Sendable, Equatable {
    public enum Target: Hashable, Sendable {
        case meeting(UUID)
        case dictation(UUID)
        case dictations
    }

    public let target: Target
    public let title: String
    public let state: WorkState

    public var id: Target { target }
}

// Background work that finished or failed since the menu panel was last opened; opening it takes them, so each shows once.
@MainActor
public final class WorkNews {
    private let meetings: MeetingLibrary
    private let files: FileJob
    private var readMeetings: Int
    private var readFiles: Int

    public init(meetings: MeetingLibrary, files: FileJob) {
        self.meetings = meetings
        self.files = files
        readMeetings = meetings.landed.count
        readFiles = files.ended.count
    }

    public func take() -> [MenuNote] {
        var notes: [MenuNote] = []
        for id in meetings.landed.dropFirst(readMeetings) {
            guard case .meeting(let meeting, _)? = meetings.entries.first(where: { $0.id == .meeting(id) }) else { continue }
            notes.append(MenuNote(target: .meeting(id), title: MeetingFormat.title(meeting), state: .done))
        }
        for file in files.ended.dropFirst(readFiles) {
            notes.append(MenuNote(target: file.work.problem == nil ? .dictation(file.id) : .dictations, title: file.fileName, state: file.work))
        }
        readMeetings = meetings.landed.count
        readFiles = files.ended.count
        var seen = Set<MenuNote.Target>()
        return notes.reversed().filter { seen.insert($0.target).inserted }
    }
}
