import Foundation

public enum RemoteTranscriberError: ProblemError, Equatable {
    case overLimit(bytes: Int, limit: Int)
    case timedOut
    case serviceFailed(status: Int? = nil)

    public var problem: Problem {
        switch self {
        case .overLimit: Problem("remote-speech.over-limit", "The audio is too large for the outside service. Transcribe it on this Mac.")
        case .timedOut: Problem("remote-speech.timed-out", "The outside service took too long. Try again.", canRetry: true)
        case .serviceFailed: Problem("remote-speech.failed", "The outside service failed. Check its address and key in Settings, Speech.", canRetry: true)
        }
    }

    public var status: Int? {
        if case .serviceFailed(let status) = self { return status }
        return nil
    }
}

public struct RemoteTranscriber: Transcriber {
    public struct Configuration: Sendable {
        public var address: ServiceAddress
        public var model: String
        public var language: String
        public var key: String?
        public var sizeLimitBytes: Int
        public var timeLimit: Duration

        public init(
            address: ServiceAddress,
            model: String,
            language: String = "",
            key: String? = nil,
            sizeLimitBytes: Int = SpeechSettings.remoteSizeLimitBytes.defaultValue,
            timeLimit: Duration = .seconds(SpeechSettings.remoteTimeLimit.defaultValue)
        ) {
            self.address = address
            self.model = model
            self.language = language
            self.key = key
            self.sizeLimitBytes = sizeLimitBytes
            self.timeLimit = timeLimit
        }
    }

    public let name: String

    private let configuration: Configuration
    private let dictionary: DictionaryStore
    private let session: URLSession
    private let clock: any Clock<Duration>

    public init(
        _ configuration: Configuration,
        dictionary: DictionaryStore,
        session: URLSession = OutsideService.makeSession(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        name = configuration.model
        self.configuration = configuration
        self.dictionary = dictionary
        self.session = session
        self.clock = clock
    }

    public init?(settings: SettingsStore, keychain: any KeyStoring, dictionary: DictionaryStore) {
        guard settings.value(SpeechSettings.usesRemote) else { return nil }
        let address: ServiceAddress
        do {
            address = try ServiceAddress(settings.value(SpeechSettings.remoteAddress))
        } catch {
            Log.failure("speech-address-refused", error: error)
            return nil
        }
        let key: String?
        do {
            key = try keychain.read(SpeechSettings.remoteKeyAccount)
        } catch {
            Log.failure("speech-key-read", error: error)
            key = nil
        }
        self.init(
            Configuration(
                address: address,
                model: settings.value(SpeechSettings.remoteModel),
                language: settings.value(SpeechSettings.remoteLanguage),
                key: key,
                sizeLimitBytes: settings.value(SpeechSettings.remoteSizeLimitBytes),
                timeLimit: .seconds(settings.value(SpeechSettings.remoteTimeLimit))
            ),
            dictionary: dictionary
        )
    }

    public static func isSetUp(settings: SettingsStore) -> Bool {
        settings.value(SpeechSettings.usesRemote)
            && ServiceAddress.problem(with: settings.value(SpeechSettings.remoteAddress)) == nil
            && !settings.value(SpeechSettings.remoteModel).trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func load() async throws {}
    public func unload() async {}

    public func transcribe(samples: [Float]) async throws -> Transcript {
        let audio = WAVEncoder.encode(samples, sampleRate: Int(SpeechAudio.sampleRate))
        guard audio.count <= configuration.sizeLimitBytes else {
            Log.event("remote-transcribe-over-limit")
            throw RemoteTranscriberError.overLimit(bytes: audio.count, limit: configuration.sizeLimitBytes)
        }
        let request = makeRequest(audio: audio)
        let text: String
        do {
            text = try await withTimeLimit(configuration.timeLimit, clock: clock) { [session] in
                try await Self.send(request, with: session)
            }
        } catch is TimeLimitExceeded {
            Log.event("remote-transcribe-timed-out")
            throw RemoteTranscriberError.timedOut
        }
        return Transcript(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            audioSeconds: Double(samples.count) / SpeechAudio.sampleRate
        )
    }

    private static func send(_ request: URLRequest, with session: URLSession) async throws -> String {
        let reply: (data: Data, status: Int)
        do {
            reply = try await OutsideService.send(request, with: session)
        } catch {
            Log.failure("remote-transcribe-request", error: error)
            throw RemoteTranscriberError.serviceFailed()
        }
        guard (200..<300).contains(reply.status) else {
            throw RemoteTranscriberError.serviceFailed(status: reply.status)
        }
        guard let decoded = try? JSONDecoder().decode(TranscriptionReply.self, from: reply.data) else {
            throw RemoteTranscriberError.serviceFailed()
        }
        return decoded.text
    }

    private func makeRequest(audio: Data) -> URLRequest {
        var form = MultipartForm()
        form.add(field: "model", value: configuration.model)
        if !configuration.language.isEmpty {
            form.add(field: "language", value: configuration.language)
        }
        let words = dictionaryWords()
        if !words.isEmpty {
            form.add(field: "prompt", value: words.joined(separator: ", "))
        }
        form.add(file: "file", name: "audio.wav", type: "audio/wav", data: audio)

        var request = URLRequest(url: configuration.address.endpoint("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        if let key = configuration.key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = form.finished()
        return request
    }

    private func dictionaryWords() -> [String] {
        dictionary.loadOrEmpty("dictionary-load-remote").words
    }
}

private struct TranscriptionReply: Decodable {
    let text: String
}

private struct MultipartForm {
    let boundary = "narrari-\(UUID().uuidString)"
    private var body = Data()

    mutating func add(field: String, value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func add(file field: String, name: String, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\n".utf8))
        body.append(Data("Content-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finished() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}
