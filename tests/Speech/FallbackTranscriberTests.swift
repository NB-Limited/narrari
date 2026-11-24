import Foundation
import NarrariKit
import Testing

struct FallbackTranscriberTests {
    enum Trouble: CaseIterable {
        case serverError
        case replyWithoutText
        case neverAnswers
        case recordingTooLarge
    }

    @Test(arguments: zip(Trouble.allCases, [SpeechFallbackReason.serviceFailed, .serviceFailed, .timedOut, .overLimit]))
    func outside_service_trouble_falls_back_to_this_mac_with_the_reason(
        trouble: Trouble, reason: SpeechFallbackReason
    ) async throws {
        let arrived = Gate()
        let stub = HTTPStub { _ in
            arrived.open()
            return switch trouble {
            case .serverError: .json(#"{"error":"overloaded"}"#, status: 503)
            case .replyWithoutText: .json(#"{"error":"no speech"}"#)
            case .neverAnswers: nil
            case .recordingTooLarge: .json(#"{"text":"too big to send"}"#)
            }
        }
        let clock = TestClock()
        let folder = TemporaryFolder()
        let remote = RemoteTranscriber(
            .init(
                address: stub.address, model: "whisper-1",
                sizeLimitBytes: trouble == .recordingTooLarge ? 10_000 : 25_000_000, timeLimit: .seconds(10)
            ),
            dictionary: DictionaryStore(root: folder.url), session: stub.session, clock: clock
        )
        let local = FakeTranscriber(text: "heard on this mac")
        let transcriber = FallbackTranscriber(primary: remote, fallback: local)

        async let result = transcriber.transcribe(samples: speech(seconds: 1))
        if trouble == .neverAnswers {
            try await arrived.pass()
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(10))
        }
        let transcript = try await result

        #expect(transcript.text == "heard on this mac")
        #expect(transcript.fallbackReason == reason)
        #expect(local.sampleCounts == [16_000])
        #expect(stub.requests.count == (trouble == .recordingTooLarge ? 0 : 1))
    }

    @Test func working_outside_service_is_used_without_a_fallback() async throws {
        let stub = HTTPStub { _ in .json(#"{"text":"heard outside"}"#) }
        let folder = TemporaryFolder()
        let remote = RemoteTranscriber(
            .init(address: stub.address, model: "whisper-1"),
            dictionary: DictionaryStore(root: folder.url), session: stub.session, clock: TestClock()
        )
        let local = FakeTranscriber(text: "heard on this mac")

        let transcript = try await FallbackTranscriber(primary: remote, fallback: local).transcribe(samples: speech(seconds: 1))

        #expect(transcript == Transcript(text: "heard outside", audioSeconds: 1))
        #expect(local.sampleCounts.isEmpty)
    }
}
