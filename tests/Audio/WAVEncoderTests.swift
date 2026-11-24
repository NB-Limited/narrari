import Foundation
import NarrariKit
import Testing

struct WAVEncoderTests {
    @Test func loud_samples_clip_instead_of_wrapping() {
        let wav = WAVEncoder.encode([0, 0.5, -0.5, 1.5, -1.5], sampleRate: 16_000)

        let samples = stride(from: 44, to: wav.count, by: 2).map { Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8) }
        #expect(samples == [0, 16_384, -16_384, 32_767, -32_767])
    }
}
