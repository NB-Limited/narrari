import Foundation
import NarrariKit
import Testing

@MainActor
struct ConnectorTests {
    private let folder = TemporaryFolder()
    private let settings = ThrowawaySettings()
    private let history: HistoryStore
    private let meetings: MeetingStore
    private let context: Command.Context
    private let modern = #"{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

    init() {
        history = HistoryStore(root: folder.url.appending(path: "History"))
        meetings = MeetingStore(root: folder.url.appending(path: "Meetings")) { _ in Issue.record("nothing is trashed") }
        context = .throwaway(in: folder, settings: settings.store, history: history, meetings: meetings)
    }

    // Each line in goes through the server as a client would send it; the replies come back by id, parsed.
    private func serve(_ lines: [String]) async throws -> [[String: Any]] {
        var output = Data()
        await Connector(context: context).serve(Bytes(Data(lines.map { $0 + "\n" }.joined().utf8))) { output.append($0) }
        return try output.split(separator: UInt8(ascii: "\n")).map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
    }

    private func call(_ tool: String, _ arguments: String) -> String {
        #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"_meta":\#(modern),"name":"\#(tool)","arguments":\#(arguments)}}"#
    }

    private func text(of reply: [String: Any]) -> String? {
        ((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    private func errorCode(of reply: [String: Any]) -> Int? {
        (reply["error"] as? [String: Any])?["code"] as? Int
    }

    @Test func answers_the_handshake_of_both_protocol_revisions() async throws {
        let replies = try await serve([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":"#
                + #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{"_meta":\#(modern)}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01"}}}"#
        ])

        #expect(replies.map { "\($0["id"] ?? "none")" } == ["1", "2", "d", "4"])
        let initialized = try #require(replies[0]["result"] as? [String: Any])
        #expect(initialized["protocolVersion"] as? String == "2025-11-25")
        #expect((initialized["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((initialized["serverInfo"] as? [String: Any])?["name"] as? String == "narrari")
        #expect((replies[1]["result"] as? [String: Any])?.isEmpty == true)
        let discovered = try #require(replies[2]["result"] as? [String: Any])
        #expect(discovered["supportedVersions"] as? [String] == ["2026-07-28"])
        #expect(discovered["resultType"] as? String == "complete")
        #expect(errorCode(of: replies[3]) == -32_022)
        #expect(((replies[3]["error"] as? [String: Any])?["data"] as? [String: Any])?["requested"] as? String == "2099-01-01")
    }

    @Test func lists_three_read_only_tools() async throws {
        let replies = try await serve([#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":\#(modern)}}"#])

        let tools = try #require((replies.first?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["list", "search", "read"])
        #expect(tools.allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true })
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
    }

    @Test func each_tool_reads_the_stores() async throws {
        let meeting = Meeting(title: "Weekly sync", startedAt: Date(), app: "", source: .manual, template: "general", state: .ready)
        try await meetings.create(meeting, appName: "")
        try await meetings.write("Ship on Friday.", to: .summary, of: meeting.id)
        let id = UUID()
        try await history.append(
            HistoryEntry(id: id, startedAt: Date(), finalText: "Send the quote to Anna.", audioFile: HistoryEntry.audioFileName(for: id), outcome: .pasted)
        )

        let replies = try await serve([
            call("list", #"{"kind":"meetings","limit":5}"#),
            call("search", #"{"kind":"dictations","text":"quote"}"#),
            call("read", #"{"kind":"meetings","id":"\#(meeting.id.uuidString)","part":"summary"}"#),
            call("list", #"{"kind":"podcasts"}"#)
        ])

        #expect(text(of: replies[0])?.contains("\(meeting.id.uuidString)  ") == true)
        #expect(text(of: replies[0])?.contains("Weekly sync") == true)
        #expect(text(of: replies[1])?.contains(id.uuidString) == true)
        #expect(text(of: replies[2]) == "Ship on Friday.\n")
        #expect(text(of: replies[3]) == "kind must be meetings or dictations.")
        #expect((replies[3]["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func every_bad_line_gets_an_error_and_the_server_keeps_answering() async throws {
        let replies = try await serve([
            "{not json",
            String(repeating: "x", count: 1_048_577),
            #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#,
            call("delete", "{}"),
            call("read", #"{"kind":"meetings","id":"\#(UUID().uuidString)"}"#),
            #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#
        ])

        #expect(replies.map(errorCode(of:)) == [-32_700, -32_600, -32_601, -32_602, nil, nil])
        #expect(replies.map { ($0["error"] as? [String: Any])?["message"] as? String } == [
            "Parse error", "Request too large", "Method not found", "Unknown tool", nil, nil
        ])
        #expect(text(of: replies[4]) == "Nothing has that id. Find one with list or search.")
        #expect((replies[4]["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(replies.last?["id"] as? Int == 9)
    }
}

// The client's side of stdin, in memory.
private struct Bytes: AsyncSequence, AsyncIteratorProtocol {
    private var bytes: Data.Iterator

    init(_ data: Data) {
        bytes = data.makeIterator()
    }

    mutating func next() async -> UInt8? {
        bytes.next()
    }

    func makeAsyncIterator() -> Self {
        self
    }
}
