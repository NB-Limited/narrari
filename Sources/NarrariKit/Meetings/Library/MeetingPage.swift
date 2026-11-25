import Foundation
import Observation

// One meeting as a page: its tabs, the transcript by speaker, the steps while it is processed, and what can be changed.
@MainActor
@Observable
public final class MeetingPage {
    public enum Tab: String, CaseIterable, Sendable {
        case summary = "Summary"
        case transcript = "Transcript"
        case speakers = "Speakers"
    }

    public struct Turn: Identifiable, Sendable, Equatable {
        public let id: Int
        public let speaker: Meeting.Speaker
        // The lines by their place in the transcript.
        public let lines: [(index: Int, segment: TranscriptSegment)]

        public static func == (first: Turn, second: Turn) -> Bool {
            first.id == second.id && first.speaker == second.speaker && first.lines.map(\.segment) == second.lines.map(\.segment)
        }
    }

    public struct SpeakerRow: Identifiable, Sendable, Equatable {
        public let speaker: Meeting.Speaker
        public let detail: String
        public var id: String { speaker.id }
    }

    public struct LiveTurn: Identifiable, Sendable, Equatable {
        public let id: Int
        public let speaker: String
        public let start: Double
        public let text: String
        public let waiting: String
    }

    public private(set) var meeting: Meeting
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var summary = ""
    public private(set) var notes = ""
    public private(set) var people: [VoiceMemory.Person] = []
    public private(set) var matches: [Int] = []
    public private(set) var matchIndex = 0
    public private(set) var hasAudio = false
    public private(set) var audio: [URL] = []
    public private(set) var redoing: MeetingProcessing.Step?
    public private(set) var detectedLanguage: String?
    // Set while the notes typed last are not on disk; they stay in the field.
    public private(set) var notesProblem: Problem?
    public var tab: Tab

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored let processing: MeetingProcessing
    @ObservationIgnored let models: MeetingModels
    @ObservationIgnored let progress: MeetingTranscript.Progress
    @ObservationIgnored private let renaming: SpeakerRenaming
    @ObservationIgnored private let memory: VoiceMemory
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let query: String
    @ObservationIgnored private var saving: Task<Void, Never>?

    public init(
        meeting: Meeting, store: MeetingStore, processing: MeetingProcessing, models: MeetingModels, progress: MeetingTranscript.Progress,
        renaming: SpeakerRenaming, memory: VoiceMemory, settings: SettingsStore, query: String = ""
    ) {
        self.meeting = meeting
        self.settings = settings
        self.store = store
        self.processing = processing
        self.models = models
        self.progress = progress
        self.renaming = renaming
        self.memory = memory
        self.query = query
        tab = query.trimmingCharacters(in: .whitespaces).isEmpty ? .summary : .transcript
    }

    public var isRecording: Bool { meeting.state == .recording }

    // Lines of one speaker in a row read as one turn.
    public var turns: [Turn] {
        let names = Dictionary(meeting.speakers.map { ($0.id, $0) }) { first, _ in first }
        var turns: [Turn] = []
        for (index, segment) in segments.enumerated() {
            if let last = turns.last, last.speaker.id == segment.speaker {
                turns[turns.count - 1] = Turn(id: last.id, speaker: last.speaker, lines: last.lines + [(index, segment)])
            } else {
                let speaker = names[segment.speaker] ?? Meeting.Speaker(id: segment.speaker, name: segment.speaker)
                turns.append(Turn(id: index, speaker: speaker, lines: [(index, segment)]))
            }
        }
        return turns
    }

    public var speakerRows: [SpeakerRow] {
        meeting.speakers.map { speaker in
            let milliseconds = segments.filter { $0.speaker == speaker.id }.reduce(0) { $0 + Int(($1.end - $1.start) * 1000) }
            let origin: String? = if speaker.id == MeetingTranscript.ownerID {
                "your microphone"
            } else if speaker.isNamedByUser == true {
                "named by you"
            } else if speaker.isGuess == true {
                "guessed from the invite"
            } else if speaker.personId != nil {
                "voice match"
            } else {
                people.first { $0.id == speaker.suggestion }.map { "sounds like \($0.name)" }
            }
            let length = MeetingFormat.length(milliseconds: milliseconds)
            return SpeakerRow(speaker: speaker, detail: origin.map { "\(length), \($0)" } ?? length)
        }
    }

    // "Maria Petrova: …" a turn, a blank line between turns.
    public var transcriptText: String {
        turns.map { turn in
            "\(Self.name(of: turn.speaker)): \(turn.lines.map(\.segment.text).joined(separator: " "))"
        }
        .joined(separator: "\n\n")
    }

    // What Copy and ⌘C copy on the tab shown.
    public var copyText: String {
        switch tab {
        case .summary: summary
        case .transcript: transcriptText
        case .speakers: ""
        }
    }

    public nonisolated static func name(of speaker: Meeting.Speaker) -> String {
        speaker.id == MeetingTranscript.ownerID ? "You" : speaker.name
    }

    public var usesVoiceMemory: Bool { settings.value(MeetingsSettings.usesVoiceMemory) }

    // "Transcript, speakers and summary done; echo removal not needed".
    public var stepsLine: String {
        let order = [MeetingProcessing.Step.transcript, .echo, .speakers, .summary]
        let skipped = meeting.steps.echo.status == .done && !hasCleanedTrack
        let done = order.filter { meeting.steps[$0].status == .done && !($0 == .echo && skipped) }.map { Self.name($0).lowercased() }
        var line = done.isEmpty ? "" : ListFormatter.localizedString(byJoining: done) + " done"
        if skipped { line += line.isEmpty ? "echo removal not needed" : "; echo removal not needed" }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    // "Parakeet v3 for the transcript, Qwen3.5 2B for the summary."; nil for a meeting processed before the names were kept.
    public var madeWith: String? {
        let parts = [(meeting.speechModel, "the transcript"), (meeting.summaryMadeWith, "the summary")]
            .filter { !$0.0.isEmpty }
            .map { "\($0.0) for \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ") + "."
    }

    public var matchLine: Int? { matches.indices.contains(matchIndex) ? matches[matchIndex] : nil }

    // The lines under the playback position; two overlap when both sides talk at once.
    public func playingLines(at position: TimeInterval, isPlaying: Bool) -> Set<Int> {
        guard hasAudio, isPlaying else { return [] }
        return Set(segments.indices.filter { segments[$0].start <= position && position < segments[$0].end })
    }

    public func part(of speaker: String) -> AudioPlayback.Part {
        Self.part(of: speaker, in: segments)
    }

    // One speaker's lines in the meeting's order; lines under a second apart play as one, so the player jumps only over others.
    public nonisolated static func part(of speaker: String, in segments: [TranscriptSegment]) -> AudioPlayback.Part {
        var stretches: [Range<TimeInterval>] = []
        for line in segments.filter({ $0.speaker == speaker && $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = stretches.last, line.start < last.upperBound + joinSeconds {
                stretches[stretches.count - 1] = last.lowerBound..<max(last.upperBound, line.end)
            } else {
                stretches.append(line.start..<line.end)
            }
        }
        return AudioPlayback.Part(id: speaker, stretches: stretches)
    }

    nonisolated static let joinSeconds = 1.0

    public var matchCount: String? {
        matches.isEmpty ? nil : "\(matchIndex + 1) of \(matches.count)"
    }

    public var searchText: String { query }

    public func load() async {
        do {
            meeting = try await store.meeting(meeting.id)
            let heard = try await store.transcript(of: meeting.id)
            if heard != segments || detectedLanguage == nil {
                detectedLanguage = SpokenLanguage.main(of: SpokenLanguage.spoken(in: heard.map(\.text)))
            }
            segments = heard
            summary = SummaryLayout.plain(try await store.text(.summary, of: meeting.id))
            if saving == nil { notes = try await store.text(.notes, of: meeting.id) }
            let tracks = [try await store.audio(.microphone, of: meeting.id), try await store.audio(.system, of: meeting.id)]
            audio = tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
            hasAudio = audio.contains { $0.lastPathComponent == MeetingStore.Audio.microphone.rawValue }
            people = try await memory.people()
        } catch {
            Log.failure("meeting-page-read", error: error)
        }
        matches = segments.indices.filter { MeetingSearch.contains(segments[$0].text, query) }
        matchIndex = min(matchIndex, max(matches.count - 1, 0))
    }

    public func showMatch(by offset: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + offset + matches.count) % matches.count
    }

    // Saved as typed, one write after another.
    public func setNotes(_ text: String) {
        notes = text
        let previous = saving
        saving = Task { [weak self, store, id = meeting.id] in
            await previous?.value
            do {
                try await store.write(text, to: .notes, of: id)
                self?.notesProblem = nil
            } catch {
                Log.failure("meeting-notes-save", error: error)
                self?.notesProblem = error.problem(or: Self.notesNotSaved)
            }
        }
    }

    public func notesSaved() async {
        await saving?.value
    }

    // The words go too, so the speaker step keeps the edit; only a new transcript replaces it.
    public func edit(line index: Int, to text: String) async {
        do {
            var segments = try await store.transcript(of: meeting.id)
            guard segments.indices.contains(index), segments[index].text != text else { return }
            if var words = try await store.words(of: meeting.id) {
                words.replace(segments[index], with: text)
                try await store.write(words, of: meeting.id)
            }
            segments[index].text = text
            try await store.write(segments, of: meeting.id)
            meeting = try await store.update(meeting.id) { meeting in
                meeting.linesEdited = true
                return meeting
            }
            self.segments = segments
            Log.event("meeting-line-edited")
        } catch {
            Log.failure("meeting-line-edit", error: error)
        }
    }

    public func retry(_ step: MeetingProcessing.Step) async {
        await processing.retry(step, of: meeting.id)
        await load()
    }

    // Both are written first, so a quit before the summary lands keeps the choice for the run at launch.
    public func redoSummary(with template: String, model: String) async {
        do {
            try await store.update(meeting.id) { meeting in
                meeting.template = template
                meeting.summaryModel = model
            }
        } catch {
            Log.failure("meeting-template-save", error: error)
        }
        await redo(.summary)
    }

    public func findSpeakersAgain(count: Int) async {
        await findSpeakersAgain(\.speakerCount, count)
    }

    public func findSpeakersAgain(ownSide count: Int) async {
        await findSpeakersAgain(\.ownSideCount, count)
    }

    // Saved first, like the summary's choice, so every later run keeps the count; 0 lets the split decide.
    private func findSpeakersAgain(_ field: any WritableKeyPath<Meeting, Int> & Sendable, _ count: Int) async {
        do {
            try await store.update(meeting.id) { $0[keyPath: field] = count }
        } catch {
            Log.failure("meeting-speaker-count-save", error: error)
        }
        await redo(.speakers)
    }

    // The other side has its own track in a call; with one track the count is of everyone in the room.
    public var speakerCountTitle: String {
        hasCallTrack ? "People on the other side" : "People in the room"
    }

    public var hasCallTrack: Bool {
        segments.contains { $0.track == .system }
    }

    // "Bulgarian, detected" until one is chosen; nil while nothing is heard and none is chosen.
    public var languageLine: String? {
        if !meeting.language.isEmpty { return SpokenLanguage.name(of: meeting.language) }
        return detectedLanguage.map { "\(SpokenLanguage.name(of: $0)), detected" }
    }

    // Written first, so a quit before the summary lands keeps the choice for the run at launch.
    public func summarise(in language: String) async {
        guard redoing == nil, language != meeting.language else { return }
        do {
            try await store.update(meeting.id) { $0.language = language }
        } catch {
            Log.failure("meeting-language-save", error: error)
            return
        }
        await redo(.summary)
    }

    public func redo(_ step: MeetingProcessing.Step) async {
        guard redoing == nil else { return }
        redoing = step
        await retry(step)
        redoing = nil
    }

    // A step at work or waiting to run; asking for another run then would do nothing.
    public var isProcessing: Bool {
        redoing != nil || MeetingProcessing.Step.allCases.contains { [.running, .waiting].contains(meeting.steps[$0].status) }
    }

    // The invited names the owner may say are their own.
    public var invitedNames: [String] { meeting.attendees.map(\.name) }

    // The name leaves this meeting's people and is left out of every later meeting's.
    public func ownerIs(_ name: String) async {
        let known = settings.value(MeetingsSettings.ownNames)
        if !known.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            settings.set(known + [name], for: MeetingsSettings.ownNames)
        }
        do {
            try await store.update(meeting.id) { $0.attendees.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        } catch {
            Log.failure("meeting-own-name-save", error: error)
        }
        await load()
    }

    public func menu(for speaker: Meeting.Speaker, query: String) -> [SpeakerMenu.Row] {
        SpeakerMenu.rows(for: speaker, in: meeting, people: people, query: query)
    }

    public func choose(_ action: SpeakerMenu.Action, for speaker: String) async {
        do {
            switch action {
            case .person(let person): try await renaming.rename(speaker, in: meeting.id, toPerson: person)
            case .name(let name): try await renaming.rename(speaker, in: meeting.id, to: name)
            case .merge(let other): try await renaming.merge(speaker, into: other, in: meeting.id)
            case .notThisPerson: try await renaming.notThisPerson(speaker, in: meeting.id)
            }
        } catch {
            Log.failure("meeting-speaker-change", error: error)
        }
        await load()
    }

    // Each live line is a turn; a side's words still changing follow its newest line.
    public static func liveTurns(_ lines: [LiveTranscript.Line], waiting: [TranscriptSegment.Track: String]) -> [LiveTurn] {
        let newest = Dictionary(lines.map { ($0.track, $0.id) }) { _, last in last }
        var turns = lines.map { line in
            LiveTurn(
                id: line.id, speaker: line.speaker, start: line.start, text: line.text,
                waiting: newest[line.track] == line.id ? waiting[line.track] ?? "" : ""
            )
        }
        for track in [TranscriptSegment.Track.mic, .system] where newest[track] == nil {
            if let words = waiting[track] {
                turns.append(LiveTurn(id: -1 - turns.count, speaker: LiveTranscript.speaker(of: track), start: 0, text: "", waiting: words))
            }
        }
        return turns
    }

    var hasCleanedTrack: Bool {
        guard let microphone = audio.first else { return false }
        return FileManager.default.fileExists(
            atPath: microphone.deletingLastPathComponent().appending(path: MeetingStore.Audio.cleanedMicrophone.rawValue).path
        )
    }

    static let notesNotSaved = Problem("meeting.notes-not-saved", "Your notes could not be saved. They stay here; type again to try once more.")

    nonisolated static func name(_ step: MeetingProcessing.Step) -> String {
        switch step {
        case .transcript: "Transcript"
        case .echo: "Echo removal"
        case .speakers: "Speakers"
        case .summary: "Summary"
        }
    }
}
