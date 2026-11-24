import Foundation
import NarrariKit

// Made-up words from syllables without q, w, x or y, so the miss query below is never in the data.
enum SpeedText {
    private static let syllables = ["ka", "lo", "mi", "ren", "tu", "va", "sel", "do", "fi", "nor", "pa", "zu", "bem", "ti", "go", "ral"]
    private static let vocabulary = syllables.flatMap { first in syllables.map { first + $0 } }
        + syllables.flatMap { first in syllables.flatMap { second in syllables.map { first + second + $0 } } }

    static let miss = "qwyxt"
    // A word in about one dictation of a hundred, as a search for a name or a topic finds.
    static let found = vocabulary[17]

    static func sentence(_ count: Int, seed: Int) -> String {
        (0..<count).map { index in
            let mixed = UInt(bitPattern: (index &* 40_503) &+ (seed &* 2_654_435_761))
            return vocabulary[Int(mixed % UInt(vocabulary.count))]
        }.joined(separator: " ")
    }
}

enum SpeedData {
    static let meetingMinutes = 60
    // One line about every six seconds of a call, fifteen words long: 9,000 words an hour.
    private static let linesPerMinute = 10
    private static let wordsPerLine = 15
    private static let dictationsPerDay = 40
    private static let apps = ["com.example.writer", "com.example.mail", "com.example.chat"]

    static func meetingStore(_ root: URL) -> MeetingStore {
        MeetingStore(root: root, trash: { try FileManager.default.removeItem(at: $0) })
    }

    static func meetings(_ count: Int, in root: URL, now: Date) async throws -> [UUID] {
        let store = meetingStore(root)
        var ids: [UUID] = []
        for index in 0..<count {
            let meeting = Meeting(
                title: "Meeting \(index)", startedAt: now.addingTimeInterval(-Double(index) * 86_400), app: "", source: .call,
                template: "", state: .ready
            )
            try await store.create(meeting, appName: "")
            let segments = (0..<(meetingMinutes * linesPerMinute)).map { line in
                TranscriptSegment(
                    start: Double(line) * 6, end: Double(line) * 6 + 5, speaker: line.isMultiple(of: 2) ? "s1" : "s2",
                    text: SpeedText.sentence(wordsPerLine, seed: index * 10_000 + line), track: line.isMultiple(of: 2) ? .mic : .system
                )
            }
            try await store.write(segments, of: meeting.id)
            try await store.write(SpeedText.sentence(80, seed: -index), to: .notes, of: meeting.id)
            try await store.write(SpeedText.sentence(250, seed: -index - 1), to: .summary, of: meeting.id)
            ids.append(meeting.id)
        }
        return ids
    }

    static func dictation(_ index: Int, now: Date) -> HistoryEntry {
        let id = UUID()
        let day = Double(index / dictationsPerDay) * 86_400
        let minute = Double(index % dictationsPerDay) * 60
        return HistoryEntry(
            id: id, startedAt: now.addingTimeInterval(-day - minute), durationMs: 9_000, app: apps[index % apps.count],
            rawText: SpeedText.sentence(40, seed: index), finalText: SpeedText.sentence(38, seed: index + 1),
            audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted
        )
    }

    static func history(_ count: Int, in root: URL, now: Date) async throws {
        let store = HistoryStore(root: root)
        for index in 0..<count {
            try await store.append(dictation(index, now: now))
        }
    }
}
