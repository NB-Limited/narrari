import Foundation

// One line of transcript.json. Times are seconds from the start of the meeting.
public struct TranscriptSegment: Codable, Sendable, Equatable {
    public enum Track: String, Codable, Sendable {
        case mic
        case system
    }

    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public var track: Track

    public init(start: Double, end: Double, speaker: String, text: String, track: Track) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.track = track
    }

    // transcript.md, for a person to read; it is written from transcript.json and never read back.
    static func markdown(_ segments: [Self], speakers: [Meeting.Speaker]) -> String {
        let names = Dictionary(speakers.map { ($0.id, $0.name) }) { first, _ in first }
        return segments.map { segment in
            let seconds = max(0, Int(segment.start))
            let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            return "[\(time)] \(names[segment.speaker] ?? segment.speaker): \(segment.text)\n"
        }
        .joined(separator: "\n")
    }
}
