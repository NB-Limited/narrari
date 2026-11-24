import Foundation

public struct FallbackTranscriber: Transcriber {
    private let primary: any Transcriber
    private let fallback: any Transcriber

    public var name: String { primary.name }

    public init(primary: any Transcriber, fallback: any Transcriber) {
        self.primary = primary
        self.fallback = fallback
    }

    public func load() async throws {
        try await fallback.load()
        try await primary.load()
    }

    public func unload() async {
        await primary.unload()
        await fallback.unload()
    }

    public func transcribe(samples: [Float]) async throws -> Transcript {
        let reason: SpeechFallbackReason
        do {
            return try await primary.transcribe(samples: samples)
        } catch RemoteTranscriberError.overLimit {
            reason = .overLimit
        } catch RemoteTranscriberError.timedOut {
            reason = .timedOut
        } catch {
            reason = .serviceFailed
        }
        try Task.checkCancellation()
        Log.event("speech-fallback")
        let transcript = try await fallback.transcribe(samples: samples)
        return Transcript(text: transcript.text, audioSeconds: transcript.audioSeconds, fallbackReason: reason)
    }
}
