import Foundation

public struct JSONFile<Value: Codable & Sendable>: Sendable {
    public let url: URL
    private let empty: Value

    public init(_ url: URL, empty: Value) {
        self.url = url
        self.empty = empty
    }

    public func load() throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    // The only write, and it reads the file again first, so a file that can't be read is never written over.
    @discardableResult
    public func edit(_ change: (inout Value) throws -> Void) throws -> Value {
        var value = try load()
        try change(&value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try AppPaths.makeOwnerOnly(url)
        return value
    }
}
