@preconcurrency import FluidAudio
import Foundation

// Who spoke when on one track, and a voice print for each speaker with enough clean speech.
public struct SpeakerSplit: Sendable, Equatable {
    public struct Turn: Sendable, Equatable {
        public let speaker: String
        public let start: Double
        public let end: Double

        public init(speaker: String, start: Double, end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    static let modelVariant = "offline"
    // VBx's Fa, 0.07 in FluidAudio. On 87 labelled recordings 0.08 to 0.10 told 9 more apart; from 0.11 one phone voice split in two.
    static let acousticWeight = 0.09

    public let turns: [Turn]
    // 256 numbers each, of unit length. A speaker with under 4 seconds of speech nobody else talks over has none.
    public let prints: [String: [Float]]

    public init(turns: [Turn], prints: [String: [Float]]) {
        self.turns = turns
        self.prints = prints
    }

    // FluidAudio's offline pipeline; `speakers` forces how many it finds. A model not on disk is never fetched here.
    public static func run(on track: URL, speakers: Int?, models: ModelStore) async throws -> SpeakerSplit {
        let folder = AudioModel.speakerSplit.folder
        guard models.isPresent(named: folder) else { throw AudioModelError.notDownloaded }
        var config = OfflineDiarizerConfig()
        config.exposeChunkEmbeddings = true
        config.clustering.warmStartFa = acousticWeight
        config.clustering.numSpeakers = speakers
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: try await OfflineDiarizerModels.load(from: models.directory(named: folder).deletingLastPathComponent()))
        let result: DiarizationResult
        do {
            result = try await manager.process(track)
        } catch OfflineDiarizationError.noSpeechDetected {
            return SpeakerSplit(turns: [], prints: [:])
        }
        let turns = result.segments.map { Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        return SpeakerSplit(turns: turns, prints: SpeakerUtilities.cleanEmbeddingsBySpeaker(result))
    }
}
