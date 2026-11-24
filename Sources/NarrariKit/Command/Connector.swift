import Foundation

// narrari mcp: a Model Context Protocol server, one JSON-RPC 2.0 message per line in and out, read-only, no network.
// It speaks revision 2026-07-28, where each request names its version in _meta, and 2025-11-25, which opens with initialize.
public struct Connector: Sendable {
    let context: Command.Context

    fileprivate static let modernVersion = "2026-07-28"
    private static let legacyVersion = "2025-11-25"
    private static let lineLimit = 1_048_576
    private static let versionKey = "io.modelcontextprotocol/protocolVersion"
    private static let newline = UInt8(ascii: "\n")
    private static let defaultLimit = 50
    private static let maximumLimit = 200

    public init(context: Command.Context) {
        self.context = context
    }

    // Answers each line as it comes and returns when the input ends. Bytes are read off the main actor, lines answered on it.
    public func serve<Bytes: AsyncSequence>(_ bytes: Bytes, write: @MainActor (Data) -> Void) async where Bytes.Element == UInt8 {
        var line: [UInt8] = []
        var isTooLong = false
        var requests = 0
        func send(_ reply: JSONValue?) async {
            guard let reply, var data = try? Self.encoder.encode(reply) else { return }
            data.append(Self.newline)
            await write(data)
        }
        do {
            for try await byte in bytes {
                guard byte == Self.newline else {
                    if line.count < Self.lineLimit { line.append(byte) } else { isTooLong = true }
                    continue
                }
                if isTooLong || !line.isEmpty {
                    requests += 1
                    await send(isTooLong ? Self.error(Failure.tooLarge, id: nil) : await reply(to: line))
                }
                line.removeAll(keepingCapacity: true)
                isTooLong = false
            }
            if isTooLong || !line.isEmpty {
                requests += 1
                await send(isTooLong ? Self.error(Failure.tooLarge, id: nil) : await reply(to: line))
            }
        } catch {
            Log.failure("connector-input", error: error)
        }
        Log.count("connector-requests", requests)
    }

    @MainActor
    private func reply(to line: [UInt8]) async -> JSONValue? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { return Self.error(Failure.parse, id: nil) }
        let id = message["id"]
        let isIDValid = switch id {
        case .string?, .number?: true
        default: false
        }
        guard message["jsonrpc"] == "2.0", case .string(let method)? = message["method"], id == nil || isIDValid else {
            return Self.error(Failure.invalid, id: isIDValid ? id : nil)
        }
        // A notification, such as notifications/initialized, gets no answer.
        guard let id else { return nil }
        let params = message["params"]
        let era: Era
        switch params?["_meta"]?[Self.versionKey] {
        case nil: era = .legacy
        case .string(Self.modernVersion)?: era = .modern
        case let other?: return Self.error(Failure.unsupported(other), id: id)
        }
        do {
            return ["jsonrpc": "2.0", "id": id, "result": try await result(of: method, params: params, era: era)]
        } catch let failure as Failure {
            return Self.error(failure, id: id)
        } catch {
            return Self.error(Failure.unreadable, id: id)
        }
    }

    private enum Era {
        case modern
        case legacy
    }

    @MainActor
    private func result(of method: String, params: JSONValue?, era: Era) async throws -> JSONValue {
        switch method {
        case "initialize":
            return [
                "protocolVersion": .string(Self.legacyVersion), "capabilities": ["tools": [:]],
                "serverInfo": Self.serverInfo, "instructions": Self.instructions
            ]
        case "server/discover":
            return Self.finished(
                ["supportedVersions": [.string(Self.modernVersion)], "capabilities": ["tools": [:]], "instructions": Self.instructions],
                era: .modern, isCacheable: true
            )
        case "ping":
            return Self.finished([:], era: era)
        case "tools/list":
            return Self.finished(["tools": Self.tools], era: era, isCacheable: true)
        case "tools/call":
            return Self.finished(try await call(params), era: era)
        default:
            throw Failure.unknownMethod
        }
    }

    // A modern result says it is complete and who answered; one that names no person's data may be cached.
    private static func finished(_ fields: [String: JSONValue], era: Era, isCacheable: Bool = false) -> JSONValue {
        guard era == .modern else { return .object(fields) }
        var fields = fields
        fields["resultType"] = "complete"
        fields["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
        if isCacheable {
            fields["ttlMs"] = 0
            fields["cacheScope"] = "public"
        }
        return .object(fields)
    }

    // A wrong argument or id is the tool's answer, which the model can read and correct; a wrong tool is a protocol error.
    @MainActor
    private func call(_ params: JSONValue?) async throws -> [String: JSONValue] {
        guard case .string(let name)? = params?["name"], let tool = Tool(rawValue: name) else { throw Failure.unknownTool }
        do {
            return ["content": [["type": "text", "text": .string(try await run(tool, with: params?["arguments"] ?? [:]))]]]
        } catch let problem as ArgumentProblem {
            return ["content": [["type": "text", "text": .string(problem.message)]], "isError": true]
        }
    }

    @MainActor
    private func run(_ tool: Tool, with arguments: JSONValue) async throws -> String {
        guard case .string(let name)? = arguments["kind"], let kind = RecordKind(rawValue: name) else { throw ArgumentProblem.kind }
        let limit = try Self.limit(arguments["limit"])
        switch tool {
        case .list:
            let since = try arguments["since"].map { value in
                guard case .string(let text) = value, let day = RecordKind.day(text) else { throw ArgumentProblem.since }
                return day
            }
            return try await reading { try await kind.command.list(since: since, limit: limit, asJSON: false, in: context) }
        case .search:
            guard case .string(let text)? = arguments["text"] else { throw ArgumentProblem.text }
            return try await reading { try await kind.command.search(text, limit: limit, in: context) }
        case .read:
            guard case .string(let text)? = arguments["id"] else { throw ArgumentProblem.id }
            let part = try arguments["part"].map { value in
                guard case .string(let name) = value, let part = MeetingPart(rawValue: name) else { throw ArgumentProblem.part }
                return part
            }
            guard let id = UUID(uuidString: text),
                  let found = try await reading({ try await kind.command.read(id, part: part, in: context) })
            else { throw ArgumentProblem.unknownID }
            return found
        }
    }

    @MainActor
    private func reading<Value>(_ read: () async throws -> Value) async throws -> Value {
        do {
            return try await read()
        } catch {
            Log.failure("connector-read", error: error)
            throw Failure.unreadable
        }
    }

    private static func limit(_ value: JSONValue?) throws -> Int {
        guard let value else { return defaultLimit }
        guard case .number(let number) = value, let limit = Int(exactly: number), (1...maximumLimit).contains(limit) else {
            throw ArgumentProblem.limit(maximum: maximumLimit)
        }
        return limit
    }

    private static func error(_ failure: Failure, id: JSONValue?) -> JSONValue {
        var error: [String: JSONValue] = ["code": .number(Double(failure.code)), "message": .string(failure.message)]
        if let data = failure.data { error["data"] = data }
        var reply: [String: JSONValue] = ["jsonrpc": "2.0", "error": .object(error)]
        if let id { reply["id"] = id }
        return .object(reply)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static var serverInfo: JSONValue {
        ["name": "narrari", "title": "Narrari", "version": .string(DoctorFacts.version())]
    }

    private static let instructions: JSONValue = """
        Meetings and dictations recorded with Narrari on this Mac, read-only. Find an id with list or search, then read it.
        """
}

private enum Tool: String {
    case list
    case search
    case read
}

private struct Failure: Error {
    let code: Int
    let message: String
    var data: JSONValue?

    static let parse = Failure(code: -32_700, message: "Parse error")
    static let invalid = Failure(code: -32_600, message: "Invalid request")
    static let tooLarge = Failure(code: -32_600, message: "Request too large")
    static let unknownMethod = Failure(code: -32_601, message: "Method not found")
    static let unknownTool = Failure(code: -32_602, message: "Unknown tool")
    static let unreadable = Failure(code: -32_603, message: "Narrari's files could not be read")

    static func unsupported(_ requested: JSONValue) -> Failure {
        let requested: JSONValue = if case .string = requested { requested } else { "" }
        return Failure(
            code: -32_022, message: "Unsupported protocol version",
            data: ["supported": [.string(Connector.modernVersion)], "requested": requested]
        )
    }
}

private enum ArgumentProblem: Error {
    case kind
    case limit(maximum: Int)
    case since
    case text
    case id
    case part
    case unknownID

    var message: String {
        switch self {
        case .kind: "kind must be meetings or dictations."
        case .limit(let maximum): "limit must be a whole number from 1 to \(maximum)."
        case .since: "since must be a day written as 2026-11-22."
        case .text: "text is required."
        case .id: "id is required."
        case .part: "part must be summary, notes or transcript."
        case .unknownID: "Nothing has that id. Find one with list or search."
        }
    }
}

private extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }
}

extension Connector {
    private static let kindArgument: JSONValue = ["type": "string", "enum": ["meetings", "dictations"]]
    private static let limitArgument: JSONValue = [
        "type": "integer", "minimum": 1, "maximum": .number(Double(maximumLimit)), "default": .number(Double(defaultLimit)),
        "description": "How many rows at most."
    ]

    fileprivate static let tools: JSONValue = [
        tool(
            "list", title: "List meetings or dictations",
            description: "Meetings or dictations, newest first, one row each: id, start, length, and the title or the first words.",
            properties: [
                "kind": kindArgument, "limit": limitArgument,
                "since": ["type": "string", "description": "Only those from this day on, written as 2026-11-22."]
            ],
            required: ["kind"]
        ),
        tool(
            "search", title: "Search meetings or dictations",
            description: """
                Meetings whose title, attendees, speakers, notes, summary or transcript hold the text, \
                or dictations whose text or app holds it. Case and accents are ignored.
                """,
            properties: ["kind": kindArgument, "text": ["type": "string"], "limit": limitArgument],
            required: ["kind", "text"]
        ),
        tool(
            "read", title: "Read a meeting or dictation",
            description: "One meeting's summary, notes and transcript, or one dictation's text, by the id from list or search.",
            properties: [
                "kind": kindArgument, "id": ["type": "string"],
                "part": [
                    "type": "string", "enum": ["summary", "notes", "transcript"],
                    "description": "Meetings only: just this part. Leave it out for all three."
                ]
            ],
            required: ["kind", "id"]
        )
    ]

    private static func tool(
        _ name: String, title: String, description: String, properties: [String: JSONValue], required: [JSONValue]
    ) -> JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "inputSchema": ["type": "object", "properties": .object(properties), "required": .array(required), "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false]
        ]
    }
}
