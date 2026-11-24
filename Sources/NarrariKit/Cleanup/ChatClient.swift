import Foundation

public struct ChatClient: CleanupEngine {
    public let name: String
    public let runsInApp = false
    public var state: ModelState { .ready }

    private let endpoint: URL
    private let key: String?
    private let session: URLSession

    public init(address: ServiceAddress, model: String, key: String?, session: URLSession = OutsideService.makeSession()) {
        name = model
        endpoint = address.endpoint("chat/completions")
        self.key = key
        self.session = session
    }

    public static func isSetUp(settings: SettingsStore) -> Bool {
        ServiceAddress.problem(with: settings.value(CleanupSettings.chatAddress)) == nil
            && !settings.value(CleanupSettings.chatModel).trimmingCharacters(in: .whitespaces).isEmpty
    }

    public init?(settings: SettingsStore, keychain: any KeyStoring) {
        let text = settings.value(CleanupSettings.chatAddress)
        guard !text.isEmpty else {
            Log.failure("chat-address-missing")
            return nil
        }
        let address: ServiceAddress
        do {
            address = try ServiceAddress(text)
        } catch {
            Log.failure("chat-address-refused", error: error)
            return nil
        }
        let key: String?
        do {
            key = try keychain.read(CleanupSettings.chatKeyAccount)
        } catch {
            Log.failure("chat-key-read", error: error)
            key = nil
        }
        self.init(address: address, model: settings.value(CleanupSettings.chatModel), key: key)
    }

    public func load() async throws {}
    public func unload() async {}

    public func rewrite(_ transcript: String, instruction: String, growth _: ReplyGrowth) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: name,
            messages: [.init(role: "system", content: instruction), .init(role: "user", content: transcript)],
            temperature: 0,
            stream: false
        ))

        let reply: (data: Data, status: Int)
        do {
            reply = try await OutsideService.send(request, with: session)
        } catch {
            Log.failure("chat-request", error: error)
            throw CleanupEngineError.generationFailed()
        }
        guard (200..<300).contains(reply.status) else {
            throw CleanupEngineError.generationFailed(status: reply.status)
        }
        guard
            let decoded = try? JSONDecoder().decode(ChatReply.self, from: reply.data),
            let content = decoded.choices.first?.message.content
        else {
            throw CleanupEngineError.generationFailed()
        }
        return content
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool
}

private struct ChatReply: Decodable {
    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }

    let choices: [Choice]
}
