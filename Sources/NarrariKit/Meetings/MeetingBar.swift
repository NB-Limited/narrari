import Foundation

// What shows while a meeting records: the recorder pill, a chip that appears on hover, or nothing until the recording has a problem.
public enum MeetingBar: String, CaseIterable, Sendable {
    case pill
    case chip
    case hidden
}
