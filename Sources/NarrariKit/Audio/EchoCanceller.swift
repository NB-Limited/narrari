import FluidAudio
import Foundation

// LocalVQE over a whole track, a second at a time: what the speakers played, heard by the microphone, is taken out.
public struct EchoCanceller: Sendable {
    private static let blockSamples = 4 * AudioModel.echoRemovalConfig.chunk.samplesPerCall

    private let store: ModelStore

    public init(store: ModelStore) {
        self.store = store
    }

    public func clean(_ microphone: URL, reference: URL, to output: URL) async throws {
        let model = try await AudioModel.echoRemoval.load(from: store)
        let stream = try await LocalVqeManager(config: AudioModel.echoRemovalConfig, model: model).makeStream()
        let heard = try TrackReader(microphone)
        let played = try TrackReader(reference)
        let writer = try TrackWriter(writingTo: output, sourceRate: SpeechAudio.sampleRate)
        var written = 0
        func write(_ samples: [Float]) {
            samples.withUnsafeBufferPointer { writer.append($0, at: Double(written) / SpeechAudio.sampleRate) }
            written += samples.count
        }
        while let block = try heard.next(Self.blockSamples) {
            try Task.checkCancellation()
            var reference = try played.next(block.count) ?? []
            reference += repeatElement(0, count: block.count - reference.count)
            write(try await stream.enhance(mic: block, reference: reference))
        }
        write(try await stream.flush())
        try writer.finish(at: Double(heard.sampleCount) / SpeechAudio.sampleRate)
    }
}
