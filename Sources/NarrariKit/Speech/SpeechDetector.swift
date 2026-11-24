import FluidAudio
import Foundation

// Which blocks of a track hold speech, by Silero VAD at FluidAudio's default threshold.
public struct SpeechDetector: Sendable {
    public static let blockSeconds = Double(VadManager.chunkSize) / SpeechAudio.sampleRate

    private let store: ModelStore

    public init(store: ModelStore) {
        self.store = store
    }

    public func speech(in track: URL) async throws -> [Bool] {
        let manager = VadManager(vadModel: try await AudioModel.speechDetection.load(from: store))
        let threshold = await manager.config.defaultThreshold
        var state = await manager.makeStreamState()
        let reader = try TrackReader(track)
        var flags: [Bool] = []
        while let block = try reader.next(VadManager.chunkSize) {
            try Task.checkCancellation()
            let result = try await manager.processStreamingChunk(block, state: state)
            state = result.state
            flags.append(result.probability >= threshold)
        }
        return flags
    }
}
