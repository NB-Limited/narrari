import Foundation

public struct Mode: Codable, Sendable, Equatable, Identifiable {
    public enum Speech: String, Codable, Sendable {
        case local
        case outside
    }

    public var id: String
    public var name: String
    public var promptID: String
    public var isCleanupOn: Bool
    public var speech: Speech

    public init(
        id: String = UUID().uuidString,
        name: String,
        promptID: String = Prompt.tidy.id,
        isCleanupOn: Bool = true,
        speech: Speech = .local
    ) {
        self.id = id
        self.name = name
        self.promptID = promptID
        self.isCleanupOn = isCleanupOn
        self.speech = speech
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        promptID = try container.decodeIfPresent(String.self, forKey: .promptID) ?? Prompt.tidy.id
        isCleanupOn = try container.decodeIfPresent(Bool.self, forKey: .isCleanupOn) ?? true
        speech = try container.decodeIfPresent(Speech.self, forKey: .speech) ?? .local
    }
}

extension Mode {
    public static let dictation = Mode(id: "dictation", name: "Dictation")
}
