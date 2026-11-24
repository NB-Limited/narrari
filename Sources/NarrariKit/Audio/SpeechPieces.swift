import Foundation

// A file's audio at the speech rate in pieces of at most 5 minutes, so a recording of any length never sits in memory.
// Each piece ends at the quietest moment of its last 30 seconds, so a cut falls between words.
public final class SpeechPieces {
    public struct Piece: Sendable {
        let offset: Int
        public let samples: [Float]

        // Seconds from the start of the file.
        public var start: Double { Double(offset) / SpeechAudio.sampleRate }
        public var end: Double { Double(offset + samples.count) / SpeechAudio.sampleRate }
    }

    public let duration: TimeInterval
    private let source: AudioFileDecoder.Source
    private let length: Int
    private let search: Int
    private var pending: [Float] = []
    private var handedOut = 0
    private var isRead = false

    private static let frame = Int(0.05 * SpeechAudio.sampleRate)

    public init(url: URL, upTo limit: TimeInterval?, pieceSeconds: Double = 300, searchSeconds: Double = 30) async throws {
        source = try await AudioFileDecoder.Source(url: url, upTo: limit)
        duration = source.duration
        length = Int(pieceSeconds * SpeechAudio.sampleRate)
        search = min(Int(searchSeconds * SpeechAudio.sampleRate), length)
    }

    public func next() throws -> Piece? {
        while !isRead, pending.count < length {
            if let block = try source.next() { pending += block } else { isRead = true }
        }
        guard !pending.isEmpty else { return nil }
        let cut = pending.count < length ? pending.count : quietest(in: length - search..<length)
        let piece = Piece(offset: handedOut, samples: Array(pending[..<cut]))
        pending.removeFirst(cut)
        handedOut += cut
        return piece
    }

    private func quietest(in range: Range<Int>) -> Int {
        let frames = stride(from: range.lowerBound, to: range.upperBound - Self.frame + 1, by: Self.frame).map { ($0, energy(at: $0)) }
        let start = frames.min { $0.1 < $1.1 }?.0 ?? range.upperBound - Self.frame
        return max(start + Self.frame / 2, 1)
    }

    private func energy(at start: Int) -> Float {
        pending[start..<start + Self.frame].reduce(0) { $0 + $1 * $1 }
    }
}
