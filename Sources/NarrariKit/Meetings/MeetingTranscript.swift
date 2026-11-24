import Foundation
import Observation

// Each track transcribed as a file is, with word timings; words grouped into segments; both tracks in time order.
public struct MeetingTranscript: MeetingStep {
    public typealias Transcribe = @Sendable (URL, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript

    // How far each meeting's transcript has come while it is written, for its step row.
    @MainActor
    @Observable
    public final class Progress {
        public private(set) var fractions: [UUID: Double] = [:]

        public init() {}

        nonisolated func report(_ fraction: Double?, of id: UUID) {
            Task { @MainActor in self.fractions[id] = fraction }
        }
    }

    // Each track's words with their times, kept so the speaker step can cut the segments again where the speaker changes.
    public struct Words: Codable, Sendable, Equatable {
        public var mic: [Transcript.Word]
        public var system: [Transcript.Word]

        public init(mic: [Transcript.Word], system: [Transcript.Word] = []) {
            self.mic = mic
            self.system = system
        }

        // An edited line takes the place of its words, spread over its time, so the speaker step cuts the edit again.
        mutating func replace(_ line: TranscriptSegment, with text: String) {
            let typed = text.split(whereSeparator: \.isWhitespace).map(String.init)
            var words = line.track == .mic ? mic : system
            let inside = words.indices.filter { words[$0].start >= line.start && words[$0].end <= line.end }
            guard let first = inside.first, let last = inside.last else { return }
            let span = (line.end - line.start) / Double(max(typed.count, 1))
            let replaced = typed.count == inside.count
                ? zip(inside, typed).map { Transcript.Word(text: $1, start: words[$0].start, end: words[$0].end) }
                : typed.enumerated().map { Transcript.Word(text: $1, start: line.start + Double($0) * span, end: line.start + Double($0 + 1) * span) }
            words.replaceSubrange(first...last, with: replaced)
            if line.track == .mic { mic = words } else { system = words }
        }
    }

    public static let ownerID = "owner"
    // Everyone on the system track, until the speaker step splits them.
    public static let othersID = "others"
    static let othersName = SpeakerNaming.numberedName(2)
    static let pauseSeconds = 1.0

    private let transcribe: Transcribe
    private let pipeline: TextPipeline
    private let ownerName: String
    private let modelName: @Sendable () -> String
    private let progress: Progress?

    public init(
        transcribe: @escaping Transcribe, pipeline: TextPipeline, ownerName: String, modelName: @escaping @Sendable () -> String,
        progress: Progress? = nil
    ) {
        self.transcribe = transcribe
        self.pipeline = pipeline
        self.ownerName = ownerName
        self.modelName = modelName
        self.progress = progress
    }

    public func run(_ id: UUID, in store: MeetingStore) async throws {
        let cleaned = try await store.audio(.cleanedMicrophone, of: id)
        let microphone = Self.exists(cleaned) ? cleaned : try await store.audio(.microphone, of: id)
        let system = try await store.audio(.system, of: id)
        let tracks = Self.exists(system) ? 2.0 : 1.0
        defer { progress?.report(nil, of: id) }
        var words = Words(mic: try await words(in: microphone) { [progress] in progress?.report($0 / tracks, of: id) })
        if Self.exists(system) {
            words.system = try await self.words(in: system) { [progress] in progress?.report((1 + $0) / tracks, of: id) }
        }
        let segments = Self.compose(words, pipeline: pipeline) { track, _ in track == .mic ? Self.ownerID : Self.othersID }
        var meeting = try await store.meeting(id)
        meeting.linesEdited = false
        for (speaker, name) in [(Self.ownerID, ownerName), (Self.othersID, Self.othersName)]
        where segments.contains(where: { $0.speaker == speaker }) && !meeting.speakers.contains(where: { $0.id == speaker }) {
            meeting.speakers.append(Meeting.Speaker(id: speaker, name: name))
        }
        meeting.speechModel = modelName()
        try await store.write(words, of: id)
        try await store.save(meeting)
        try await store.write(segments, of: id)
        Log.count("meeting-transcript-segments", segments.count)
    }

    // Segments of both tracks in time order, each with the dictionary's replacements applied.
    static func compose(
        _ words: Words, pipeline: TextPipeline, speaker: (TranscriptSegment.Track, _ index: Int) -> String
    ) -> [TranscriptSegment] {
        let segments = segments(words.mic, track: .mic) { speaker(.mic, $0) } + segments(words.system, track: .system) { speaker(.system, $0) }
        return ordered(segments).map { segment in
            var polished = segment
            polished.text = pipeline.file(segment.text).finalText
            return polished
        }
    }

    // A new segment starts after a pause of a second or when the speaker changes.
    static func segments(
        _ words: [Transcript.Word], track: TranscriptSegment.Track, speaker: (_ index: Int) -> String
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for (index, word) in words.enumerated() {
            let name = speaker(index)
            if var last = segments.last, last.speaker == name, word.start - last.end < pauseSeconds {
                last.end = word.end
                last.text += " " + word.text
                segments[segments.count - 1] = last
            } else {
                segments.append(TranscriptSegment(start: word.start, end: word.end, speaker: name, text: word.text, track: track))
            }
        }
        return segments
    }

    // By start time; at the same moment the microphone comes first.
    static func ordered(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.enumerated().sorted { first, second in
            let a = first.element
            let b = second.element
            if a.start != b.start { return a.start < b.start }
            if a.track != b.track { return a.track == .mic }
            return first.offset < second.offset
        }
        .map(\.element)
    }

    private func words(in track: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.Word] {
        do {
            return try await transcribe(track, progress).words
        } catch let error as TranscriberError where error == .notDownloaded {
            throw MeetingStepWaiting.speechModel
        }
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
