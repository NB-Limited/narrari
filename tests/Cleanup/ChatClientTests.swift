import Foundation
import NarrariKit
import Testing

struct ChatClientTests {
    @Test func sends_the_instruction_as_system_and_the_transcript_as_user() async throws {
        let stub = HTTPStub { _ in .json(#"{"choices":[{"message":{"role":"assistant","content":"Hello, Anna."}}]}"#) }
        let client = ChatClient(address: stub.address, model: "gpt-4.1-mini", key: "sk-test", session: stub.session)

        let reply = try await client.rewrite("hello anna", instruction: "Clean it up.", growth: Prompt.tidy.growth)

        #expect(reply == "Hello, Anna.")
        let request = try #require(stub.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/v1/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer sk-test")
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["model"] as? String == "gpt-4.1-mini")
        #expect(body["stream"] as? Bool == false)
        #expect(body["temperature"] as? Double == 0)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "Clean it up."], ["role": "user", "content": "hello anna"]])
    }

    @Test func no_key_sends_no_authorization() async throws {
        let stub = HTTPStub { _ in .json(#"{"choices":[{"message":{"content":"ok"}}]}"#) }

        let client = ChatClient(address: stub.address, model: "llama3", key: nil, session: stub.session)
        _ = try await client.rewrite("ok", instruction: "Tidy.", growth: Prompt.tidy.growth)

        #expect(stub.requests.first?.headers["Authorization"] == nil)
    }

    @Test(arguments: [
        HTTPStub.Reply.json(#"{"error":{"message":"rate limited"}}"#, status: 429),
        .json(#"{"choices":[]}"#),
        .json(#"{"choices":[{"message":{"content":null}}]}"#),
        .json(#"{"id":"chatcmpl-1"}"#),
        .json("<html>gateway</html>")
    ])
    func unusable_reply_is_a_generation_failure(reply: HTTPStub.Reply) async {
        let stub = HTTPStub { _ in reply }
        let client = ChatClient(address: stub.address, model: "gpt-4.1-mini", key: "sk-test", session: stub.session)

        await #expect {
            try await client.rewrite("hello", instruction: "Tidy.", growth: Prompt.tidy.growth)
        } throws: { error in
            if case CleanupEngineError.generationFailed = error { true } else { false }
        }
    }
}
