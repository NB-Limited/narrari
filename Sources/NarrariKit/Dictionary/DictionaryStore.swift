import Foundation

public struct Replacement: Codable, Sendable, Equatable {
    public var phrase: String
    public var text: String

    public init(phrase: String, text: String) {
        self.phrase = phrase
        self.text = text
    }
}

public struct WordList: Codable, Sendable, Equatable {
    public var words: [String]
    public var replacements: [Replacement]
    public var marks: [SpokenMark]

    public init(words: [String] = [], replacements: [Replacement] = [], marks: [SpokenMark] = SpokenMark.defaults) {
        self.words = words
        self.replacements = replacements
        self.marks = marks
    }

    // A file from before spoken marks has no list of them and gets the defaults; an emptied list stays empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        words = try container.decodeIfPresent([String].self, forKey: .words) ?? []
        replacements = try container.decodeIfPresent([Replacement].self, forKey: .replacements) ?? []
        marks = try container.decodeIfPresent([SpokenMark].self, forKey: .marks) ?? SpokenMark.defaults
    }
}

public struct DictionaryStore: Sendable {
    public static let shared = DictionaryStore(root: AppPaths.applicationSupport)
    public static let changeKey = "dictionary"

    public let file: JSONFile<WordList>

    public init(root: URL) {
        file = JSONFile(root.appending(path: "dictionary.json"), empty: WordList())
    }

    public func load() throws -> WordList {
        try file.load()
    }

    // For readers that go on without the words: a list that can't be read counts as empty.
    public func loadOrEmpty(_ failure: StaticString) -> WordList {
        do {
            return try load()
        } catch {
            Log.failure(failure, error: error)
            return WordList()
        }
    }

    @discardableResult
    public func edit(_ change: (inout WordList) throws -> Void) throws -> WordList {
        let list = try file.edit(change)
        SettingsChanges.post(Self.changeKey)
        return list
    }
}
