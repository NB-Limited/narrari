import Foundation
import NarrariKit
import Testing

struct RemoteTranscriberTests {
    private let folder = TemporaryFolder()

    @Test func uploads_a_16_khz_mono_16_bit_wav_in_a_multipart_form() async throws {
        let dictionary = DictionaryStore(root: folder.url)
        try dictionary.edit { $0 = WordList(words: ["Narrari", "Baburov"]) }
        let stub = HTTPStub { _ in .json(#"{"text":"  Здравей, Анна.  "}"#) }
        let remote = RemoteTranscriber(
            .init(address: stub.address, model: "whisper-large-v3", language: "bg", key: "sk-test"),
            dictionary: dictionary, session: stub.session, clock: TestClock()
        )
        let samples = speech(seconds: 1.5)

        let transcript = try await remote.transcribe(samples: samples)

        #expect(transcript.text == "Здравей, Анна.")
        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/v1/audio/transcriptions")
        #expect(request.headers["Authorization"] == "Bearer sk-test")
        let form = try Multipart(request)
        #expect(form.fields["model"] == "whisper-large-v3")
        #expect(form.fields["language"] == "bg")
        #expect(form.fields["prompt"] == "Narrari, Baburov")
        let wav = try #require(form.files["file"])
        #expect(wav.type == "audio/wav")
        try expectSpeechWAV(wav.data, sampleCount: samples.count)
    }

    private func expectSpeechWAV(_ data: Data, sampleCount: Int) throws {
        func text(_ offset: Int) -> String { String(decoding: data[offset..<offset + 4], as: UTF8.self) }
        func number<Value: FixedWidthInteger>(_ offset: Int, as: Value.Type) -> Value {
            data[offset..<offset + MemoryLayout<Value>.size].reversed().reduce(0) { $0 << 8 | Value($1) }
        }
        try #require(data.count >= 44)
        #expect(text(0) == "RIFF" && text(8) == "WAVE" && text(12) == "fmt " && text(36) == "data")
        #expect(number(20, as: UInt16.self) == 1)
        #expect(number(22, as: UInt16.self) == 1)
        #expect(number(24, as: UInt32.self) == 16_000)
        #expect(number(34, as: UInt16.self) == 16)
        #expect(number(40, as: UInt32.self) == UInt32(sampleCount * 2))
        #expect(number(4, as: UInt32.self) == UInt32(data.count - 8))
        #expect(data.count == 44 + sampleCount * 2)
    }
}

private struct Multipart {
    struct File {
        let type: String
        let data: Data
    }

    var fields: [String: String] = [:]
    var files: [String: File] = [:]

    init(_ request: HTTPStub.Request) throws {
        let contentType = try #require(request.headers["Content-Type"])
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        let delimiter = Data("--\(boundary)".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var rest = request.body[...]
        while let start = rest.range(of: delimiter) {
            rest = rest[start.upperBound...]
            guard rest.starts(with: Data("\r\n".utf8)), let split = rest.range(of: headerEnd),
                  let next = rest.range(of: delimiter)
            else { break }
            let headers = String(decoding: rest[rest.startIndex..<split.lowerBound], as: UTF8.self)
            let content = Data(rest[split.upperBound..<next.lowerBound].dropLast(2))
            let name = try #require(headers.firstMatch(of: /name="([^"]+)"/)?.1).description
            if let type = headers.firstMatch(of: /Content-Type: (.+)/)?.1 {
                files[name] = File(type: String(type).trimmingCharacters(in: .whitespacesAndNewlines), data: content)
            } else {
                fields[name] = String(decoding: content, as: UTF8.self)
            }
            rest = rest[next.lowerBound...]
        }
    }
}
