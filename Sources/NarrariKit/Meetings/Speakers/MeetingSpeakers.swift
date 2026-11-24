import Foundation

// Splits the track other people are on, names the speakers, and cuts the transcript again where the speaker changes.
// With two tracks the system sound is split and the microphone apart, to find anyone beside the owner; with one, as in
// a room, the whole track is.
public struct MeetingSpeakers: MeetingStep {
    // The track, and how many speakers to find in it, or nil to let the split decide.
    public typealias Split = @Sendable (URL, Int?) async throws -> SpeakerSplit

    public enum Failure: ProblemError, CaseIterable {
        case noWordTimings

        public var problem: Problem {
            Problem("speakers.no-word-timings", "The transcript has no word timings. Transcribe the meeting again.")
        }
    }

    // A speaker with less speech than this is folded into whoever spoke nearest in time.
    static let foldSeconds = 10.0

    private let split: Split
    private let memory: VoiceMemory
    private let pipeline: TextPipeline
    private let settings: SettingsStore
    private let ownerName: String

    public init(split: @escaping Split, memory: VoiceMemory, pipeline: TextPipeline, settings: SettingsStore, ownerName: String) {
        self.split = split
        self.memory = memory
        self.pipeline = pipeline
        self.settings = settings
        self.ownerName = ownerName
    }

    public init(models: ModelStore, memory: VoiceMemory, pipeline: TextPipeline, settings: SettingsStore, ownerName: String) {
        self.init(
            split: { try await SpeakerSplit.run(on: $0, speakers: $1, models: models) }, memory: memory, pipeline: pipeline, settings: settings,
            ownerName: ownerName
        )
    }

    public func run(_ id: UUID, in store: MeetingStore) async throws {
        guard let words = try await store.words(of: id) else { throw Failure.noWordTimings }
        let remembers = settings.value(MeetingsSettings.usesVoiceMemory)
        let cleaned = try await store.audio(.cleanedMicrophone, of: id)
        let microphone = FileManager.default.fileExists(atPath: cleaned.path) ? cleaned : try await store.audio(.microphone, of: id)
        let twoTracks = !words.system.isEmpty
        let meeting = try await store.meeting(id)
        let count = meeting.speakerCount > 0 ? meeting.speakerCount : nil
        let (split, side) = twoTracks
            ? try await splittingBoth(try await store.audio(.system, of: id), microphone, speakers: count, in: meeting, remembers: remembers)
            : (try await splitting(microphone, speakers: count), nil)
        let ownerPrint = remembers ? side?.ownerPrint : nil
        if let ownerPrint {
            try await memory.learn(ownerPrint, from: id, for: try await memory.owner(named: ownerName).id)
        }

        // A count the user chose keeps everyone it finds, however little they said.
        let turns = count == nil ? Self.folded(split.turns) : split.turns
        let heard = twoTracks ? words.system : words.mic
        let others = heard.map { Self.speaker(at: $0, in: turns) ?? "" }
        let micClusters = side.map { side in words.mic.map { side.cluster(at: $0) } } ?? []
        let clusters = others + micClusters.filter { $0.hasPrefix(OwnSide.guestPrefix) }
        let prints = (split.prints.merging(side?.guestPrints ?? [:]) { first, _ in first }).filter { clusters.contains($0.key) }
        let people = try await memory.people()
        let owner = people.first(where: \.isOwner)
        let known = twoTracks ? people.filter { !$0.isOwner } : people
        let matches = remembers ? SpeakerNaming.matches(prints, voices: SpeakerNaming.voices(of: known)) : [:]
        var cast = SpeakerCast(
            clusters: clusters, matches: matches, people: people, ownerHasMicrophone: twoTracks && !words.mic.isEmpty,
            ownerName: owner?.name ?? ownerName
        )
        cast.guess(meeting.attendees.map(\.name), hasPrint: { prints[$0] != nil })

        if remembers {
            var voices = Dictionary(uniqueKeysWithValues: prints.map { (cast.id(of: $0.key), $0.value) })
            voices[MeetingTranscript.ownerID] = ownerPrint
            try await store.write(voices: voices, of: id)
        }
        let mine = side.map { side in words.mic.indices.filter { side.role(at: words.mic[$0]) != .echo } } ?? Array(words.mic.indices)
        let segments = MeetingTranscript.compose(.init(mic: mine.map { words.mic[$0] }, system: words.system), pipeline: pipeline) { track, index in
            guard track == .mic, twoTracks else { return cast.id(of: others[index]) }
            let cluster = micClusters[mine[index]]
            return cluster.hasPrefix(OwnSide.guestPrefix) ? cast.id(of: cluster) : MeetingTranscript.ownerID
        }
        let speakers = cast.speakers
        try await store.update(id) { $0.speakers = speakers }
        try await store.write(segments, of: id)
        try await SpeakerRenaming(store: store, memory: memory, settings: settings)
            .replay(in: id, others: twoTracks ? Self.mostHeard(others, in: cast) : nil)
        Log.count("meeting-speakers-found", cast.order.count)
    }

    // Both tracks at once: about a third faster on an hour, for 0.7 GB more while they run.
    private func splittingBoth(
        _ system: URL, _ microphone: URL, speakers: Int?, in meeting: Meeting, remembers: Bool
    ) async throws -> (SpeakerSplit, OwnSide?) {
        async let far = splitting(system, speakers: speakers)
        async let near = splitting(microphone, speakers: meeting.ownSideCount > 0 ? meeting.ownSideCount : nil)
        let split = try await far
        let stored = remembers ? try await memory.people().first(where: \.isOwner).flatMap { SpeakerNaming.mean($0.prints.map(\.values)) } : nil
        return (split, OwnSide(try await near, ownerPrint: stored, farSpeech: split.turns, chosen: meeting.ownSideCount > 0))
    }

    // Ties go to the speaker heard first, so a rerun names the same one.
    private static func mostHeard(_ clusters: [String], in cast: SpeakerCast) -> String? {
        let words = clusters.reduce(into: [String: Int]()) { $0[cast.id(of: $1), default: 0] += 1 }
        return cast.order.map { cast.id(of: $0) }.max { words[$0, default: 0] < words[$1, default: 0] }
    }

    private func splitting(_ track: URL, speakers: Int?) async throws -> SpeakerSplit {
        do {
            return try await split(track, speakers)
        } catch AudioModelError.notDownloaded {
            throw WaitReason.speakerModel
        }
    }

    // The one who spoke most always stays, so a short meeting keeps a speaker.
    static func folded(_ turns: [SpeakerSplit.Turn]) -> [SpeakerSplit.Turn] {
        let speech = speechSeconds(turns)
        let most = speech.max { $0.value < $1.value }?.key
        return turns.filter { speech[$0.speaker, default: 0] >= foldSeconds || $0.speaker == most }
    }

    // The turn that overlaps the word most, or the nearest one when none does.
    static func speaker(at word: Transcript.Word, in turns: [SpeakerSplit.Turn]) -> String? {
        turns.max { fit(word, $0) < fit(word, $1) }?.speaker
    }

    private static func fit(_ word: Transcript.Word, _ turn: SpeakerSplit.Turn) -> Double {
        min(word.end, turn.end) - max(word.start, turn.start)
    }

    static func speechSeconds(_ turns: [SpeakerSplit.Turn]) -> [String: Double] {
        turns.reduce(into: [:]) { $0[$1.speaker, default: 0] += $1.end - $1.start }
    }
}
