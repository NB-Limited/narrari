import Foundation

public enum SpeechFallbackReason: String, Sendable {
    case serviceFailed = "service-failed"
    case timedOut = "timed-out"
    case overLimit = "over-limit"
}

public struct Transcript: Sendable, Equatable {
    // Seconds from the start of the audio.
    public struct Word: Codable, Sendable, Equatable {
        public let text: String
        public let start: Double
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public let text: String
    public let audioSeconds: Double
    public let fallbackReason: SpeechFallbackReason?
    // Read for a file only; a dictation's text can change after it is heard, so its words would not match.
    public let words: [Word]

    public init(text: String, audioSeconds: Double, fallbackReason: SpeechFallbackReason? = nil, words: [Word] = []) {
        self.text = text
        self.audioSeconds = audioSeconds
        self.fallbackReason = fallbackReason
        self.words = words
    }
}

public enum ModelState: Sendable, Equatable {
    case missing
    case preparing(fraction: Double, isDownloading: Bool = false)
    case ready
    case failed(reason: String)
}

public enum TranscriberError: Error, Equatable {
    case modelUnavailable(reason: String)
    case transcriptionFailed(reason: String)

    public static let notDownloaded = TranscriberError.modelUnavailable(reason: "the speech model is not downloaded")
}

public protocol Transcriber: Sendable {
    var name: String { get }

    func load() async throws
    func unload() async
    func transcribe(samples: [Float]) async throws -> Transcript
}
