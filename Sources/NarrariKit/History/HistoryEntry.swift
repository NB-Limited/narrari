import Foundation

public struct HistoryEntry: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case pasted
        case clipboard
        case discarded
        case failed
        // Only kept here, as the text of a transcribed file is.
        case kept
    }

    public struct Cleanup: Codable, Sendable, Equatable {
        public var model = ""
        public var status = ""
        public var reason = ""

        public init() {}
    }

    public static let currentVersion = 1

    public var version = HistoryEntry.currentVersion
    public var id: UUID
    public var startedAt: Date
    public var durationMs: Int
    public var app: String
    public var mode = ""
    public var rawText: String
    public var finalText: String
    public var cleanup = Cleanup()
    // The id of the prompt clean-up was given; nil on lines written before it was kept.
    public var prompt: String?
    // Set only when the outside speech service failed and the local model transcribed instead.
    public var speechFallback: String?
    public var speechModel: String?
    public var audioFile: String
    // The problem's code when the kept audio is shorter than the dictation; nil while it is whole.
    public var audioFailure: String?
    // The name of the file the audio came from; nil for a dictation.
    public var file: String?
    public var outcome: Outcome?
    // A tombstone: the entry was deleted, and the reader drops it.
    public var deleted: Bool?

    public init(
        id: UUID,
        startedAt: Date,
        durationMs: Int = 0,
        app: String = "",
        rawText: String = "",
        finalText: String = "",
        audioFile: String,
        outcome: Outcome? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.app = app
        self.rawText = rawText
        self.finalText = finalText
        self.audioFile = audioFile
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case id, startedAt, durationMs, app, mode, rawText, finalText, cleanup, prompt, speechFallback, speechModel, audioFile, audioFailure, file, outcome
        case deleted
    }

    public static func audioFileName(for id: UUID) -> String {
        "\(id.uuidString).caf"
    }

    // A line without an outcome is a dictation still in progress.
    public var isFinished: Bool { outcome != nil }

    public var isDeleted: Bool { deleted == true }
}

extension HistoryEntry {
    mutating func fill(with result: TextPipeline.Result) {
        rawText = result.rawText
        finalText = result.finalText
        cleanup.model = result.cleanup.model
        cleanup.status = result.cleanup.status.rawValue
        cleanup.reason = result.cleanup.reason?.rawValue ?? ""
        prompt = result.prompt.id
    }
}

extension HistoryEntry {
    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.timestamp))
        }
        return try encoder.encode(self)
    }

    init(jsonLine: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try Self.timestamp.parse(decoder.singleValueContainer().decode(String.self))
        }
        self = try decoder.decode(Self.self, from: jsonLine)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [CodingKeys.version], debugDescription: "unknown history version \(version)")
            )
        }
    }
}
