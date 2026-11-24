import AVFoundation
import NarrariKit
import Testing

struct AudioFileDecoderTests {
    private let folder = TemporaryFolder()

    @Test func web_address_is_refused_before_anything_is_fetched() async throws {
        let link = try #require(URL(string: "https://example.com/talk.m4a"))

        await #expect(throws: AudioFileError.unreadable) {
            try await AudioFileDecoder.writeTrack(from: link, to: folder.url.appending(path: "mic.caf"))
        }
    }
}
