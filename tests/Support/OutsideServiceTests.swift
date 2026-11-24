import Foundation
import NarrariKit
import Testing

struct OutsideServiceTests {
    @Test(arguments: zip(
        ["", "   ", "http://api.example.com/v1", "https://name:secret@api.example.com/v1", "ftp://api.example.com", "api.example.com/v1"],
        [ServiceAddressError.empty, .empty, .notHTTPS, .containsCredentials, .malformed, .malformed]
    ))
    func refuses_an_address_that_could_leak_a_key(text: String, error: ServiceAddressError) {
        #expect(throws: error) { try ServiceAddress(text) }
    }

    @Test(arguments: ["https://api.example.com/v1", "http://localhost:11434/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8000/v1", " HTTP://LOCALHOST:1234/v1 "])
    func accepts_https_anywhere_and_http_on_this_mac(text: String) {
        #expect(throws: Never.self) { try ServiceAddress(text) }
    }

    @Test func plain_http_address_explains_what_to_use() {
        #expect(ServiceAddress.problem(with: "http://api.example.com/v1") == ServiceAddressError.notHTTPS.message)
        #expect(ServiceAddress.problem(with: "https://api.example.com/v1") == nil)
    }

    @Test func redirect_is_not_followed() async throws {
        let elsewhere = HTTPStub { _ in .json(#"{"text":"stolen"}"#) }
        let service = HTTPStub { _ in .redirect(to: URL(string: "https://\(elsewhere.host)/v1/audio/transcriptions")!) }
        let folder = TemporaryFolder()
        let remote = RemoteTranscriber(
            .init(address: service.address, model: "whisper-1", key: "sk-test"),
            dictionary: DictionaryStore(root: folder.url), session: service.session, clock: TestClock()
        )

        await #expect(throws: RemoteTranscriberError.serviceFailed(reason: "the speech service answered with status 302")) {
            try await remote.transcribe(samples: speech(seconds: 1))
        }
        #expect(elsewhere.requests.isEmpty)
    }
}
