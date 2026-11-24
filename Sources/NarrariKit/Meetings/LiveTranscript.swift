import Foundation
import Observation

// What a track's recogniser says: drop the tokens after `retained`, append `tokens`; the first `stable` never change again.
public struct LiveEdit: Sendable {
    public struct Token: Sendable {
        // A token that starts a word begins with a space.
        public let text: String
        // Seconds since the meeting started, paused time left out.
        public let start: Double
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public let retained: Int
    public let stable: Int
    public let tokens: [Token]

    public init(retained: Int, stable: Int, tokens: [Token]) {
        self.retained = retained
        self.stable = stable
        self.tokens = tokens
    }
}

// One recogniser per track on one loaded model, for live text only.
public protocol LiveSpeech: Sendable {
    func load() async throws
    // Edits for one track, in order, until unload() or a failure ends them.
    func edits(for track: TranscriptSegment.Track) async throws -> AsyncThrowingStream<LiveEdit, any Error>
    // Called on the recording's queue with 16 kHz mono audio and its place in the meeting.
    func hear(_ samples: UnsafeBufferPointer<Float>, at position: Double, on track: TranscriptSegment.Track)
    func unload() async
}

public enum LiveTextNotice: Sendable, Equatable {
    case modelMissing
    case failed

    public var message: String {
        switch self {
        case .modelMissing: "Live text needs the speech model. The meeting is still recording."
        case .failed: "Live text stopped. The meeting is still recording."
        }
    }
}

// The meeting's words as they are spoken, for the eye only: nothing here is saved or logged, and the transcript kept
// with the meeting is made from the recorded files after the call.
@MainActor
@Observable
public final class LiveTranscript {
    public struct Line: Sendable, Identifiable {
        public let id: Int
        public let track: TranscriptSegment.Track
        public internal(set) var text: String
        public let start: Double
        public internal(set) var end: Double

        public var speaker: String { LiveTranscript.speaker(of: track) }
    }

    // Enough to scroll back over the last hour or two of talk, at a few hundred kilobytes; the whole meeting is in the
    // transcript made after the call.
    public static let maximumLines = 1_000
    static let pauseSeconds = 1.5

    public private(set) var lines: [Line] = []
    // Each side's words not yet final, shown greyed; every edit replaces them.
    public private(set) var pending: [TranscriptSegment.Track: String] = [:]
    public private(set) var notice: LiveTextNotice?
    public private(set) var isListening = false

    @ObservationIgnored private let recorder: MeetingRecorder
    @ObservationIgnored private let speech: any LiveSpeech
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var unloading: Task<Void, Never>?
    // The setting as last followed; a failure keeps live text off until the setting goes off and on again.
    @ObservationIgnored private var isWanted = false
    @ObservationIgnored private var tracks: [TranscriptSegment.Track: TrackText] = [:]
    @ObservationIgnored private var nextLineID = 0
    // Edits from an earlier run that arrive after it ended are dropped.
    @ObservationIgnored private var generation = 0

    public init(recorder: MeetingRecorder, speech: any LiveSpeech, settings: SettingsStore) {
        self.recorder = recorder
        self.speech = speech
        self.settings = settings
    }

    public nonisolated static func speaker(of track: TranscriptSegment.Track) -> String {
        switch track {
        case .mic: "You"
        case .system: "Others"
        }
    }

    // The meeting started. Live text follows its setting until stop().
    public func start() {
        guard following == nil else { return }
        let updates = SettingsChanges.updates(of: [MeetingsSettings.showsLiveText.key])
        following = Task { [weak self] in
            for await _ in updates { self?.follow() }
        }
        follow()
    }

    // The meeting ended: the recognisers let their model go. The lines stay until the next meeting starts, so the meeting's
    // page shows them until its transcript is made.
    public func stop() async {
        following?.cancel()
        following = nil
        isWanted = false
        end()
        await unloading?.value
    }

    private func follow() {
        let isWanted = settings.value(MeetingsSettings.showsLiveText)
        guard isWanted != self.isWanted else { return }
        self.isWanted = isWanted
        if isWanted {
            begin()
        } else {
            end()
            lines = []
        }
    }

    private func begin() {
        generation += 1
        let generation = generation
        lines = []
        notice = nil
        let previous = unloading
        running = Task { [weak self, speech] in
            await previous?.value
            do {
                try await speech.load()
                let mic = try await speech.edits(for: .mic)
                let system = try await speech.edits(for: .system)
                self?.listen(generation)
                try await withThrowingTaskGroup { group in
                    for (track, edits) in [(TranscriptSegment.Track.mic, mic), (.system, system)] {
                        group.addTask {
                            for try await edit in edits { await self?.apply(edit, on: track, generation) }
                        }
                    }
                    while try await group.next() != nil {}
                }
            } catch {
                self?.fail(error, generation)
            }
        }
    }

    private func listen(_ generation: Int) {
        guard generation == self.generation else { return }
        recorder.listen { [speech] track, samples, position in speech.hear(samples, at: position, on: track) }
        isListening = true
    }

    private func end() {
        generation += 1
        recorder.listen(nil)
        isListening = false
        pending = [:]
        tracks = [:]
        notice = nil
        guard let finishing = running else { return }
        running = nil
        finishing.cancel()
        unloading = Task { [speech] in
            await finishing.value
            await speech.unload()
        }
    }

    private func fail(_ error: any Error, _ generation: Int) {
        guard generation == self.generation, !(error is CancellationError) else { return }
        Log.failure("live-text", error: error)
        end()
        notice = (error as? TranscriberError) == .notDownloaded ? .modelMissing : .failed
    }

    private func apply(_ edit: LiveEdit, on track: TranscriptSegment.Track, _ generation: Int) {
        guard generation == self.generation else { return }
        var text = tracks[track] ?? TrackText()
        let confirmed = text.apply(edit)
        tracks[track] = text
        for token in confirmed where !token.text.isEmpty { add(token, on: track) }
        let waiting = text.pendingText
        pending[track] = waiting.isEmpty ? nil : waiting
    }

    // A word joins its side's last line unless that line ended a pause ago or the other side spoke since.
    private func add(_ token: LiveEdit.Token, on track: TranscriptSegment.Track) {
        let startsWord = token.text.hasPrefix(" ")
        if let last = lines.lastIndex(where: { $0.track == track }),
           !startsWord || (token.start - lines[last].end < Self.pauseSeconds && lines[(last + 1)...].allSatisfy { $0.start > token.start }) {
            lines[last].text += token.text
            lines[last].end = max(lines[last].end, token.end)
            return
        }
        let line = Line(
            id: nextLineID, track: track, text: token.text.trimmingCharacters(in: .whitespaces), start: token.start, end: token.end
        )
        nextLineID += 1
        let place = lines.lastIndex { $0.start <= line.start }.map { $0 + 1 } ?? 0
        lines.insert(line, at: place)
        if lines.count > Self.maximumLines { lines.removeFirst(lines.count - Self.maximumLines) }
    }
}

// One track's tokens since its last confirmed one.
private struct TrackText {
    private var confirmed = 0
    private var tail: [LiveEdit.Token] = []

    var pendingText: String { tail.map(\.text).joined().trimmingCharacters(in: .whitespaces) }

    // The tokens that became final with this edit.
    mutating func apply(_ edit: LiveEdit) -> ArraySlice<LiveEdit.Token> {
        tail = Array(tail.prefix(max(0, edit.retained - confirmed))) + edit.tokens
        let final = tail.prefix(max(0, edit.stable - confirmed))
        tail.removeFirst(final.count)
        confirmed += final.count
        return final
    }
}
