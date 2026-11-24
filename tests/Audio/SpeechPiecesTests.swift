import Foundation
import NarrariKit
import Testing

struct SpeechPiecesTests {
    private let folder = TemporaryFolder()

    // 12 seconds of tone with half a second of silence from 4.5 s.
    private func toneWithAGap() throws -> URL {
        let file = folder.url.appending(path: "talk.wav")
        let silence = [Float](repeating: 0, count: Int(0.5 * SpeechAudio.sampleRate))
        try WAVEncoder.encode(speech(seconds: 4.5) + silence + speech(seconds: 7), sampleRate: 16_000).write(to: file)
        return file
    }

    @Test func a_long_file_is_cut_in_its_silence_into_bounded_pieces_that_lose_and_repeat_nothing() async throws {
        let pieces = try await SpeechPieces(url: try toneWithAGap(), upTo: nil, pieceSeconds: 6, searchSeconds: 3)

        var all: [SpeechPieces.Piece] = []
        while let piece = try pieces.next() { all.append(piece) }

        #expect(all.allSatisfy { $0.end - $0.start <= 6 })
        #expect((4.5...5).contains(try #require(all.first).end))
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.end == $1.start })
        #expect(all.map(\.samples.count).reduce(0, +) == 12 * 16_000)
    }

    @Test func a_limit_refuses_a_longer_file_and_none_takes_any_length() async throws {
        let file = try toneWithAGap()

        await #expect(throws: AudioFileError.tooLong) { try await SpeechPieces(url: file, upTo: 10) }
        #expect(try await SpeechPieces(url: file, upTo: nil).duration == 12)
    }
}
