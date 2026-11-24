import Foundation

enum SetupInput {
    static func flags(_ arguments: ArraySlice<String>, allowed: Set<String>) -> [String: String]? {
        var flags: [String: String] = [:]
        var rest = arguments
        while let flag = rest.popFirst() {
            guard allowed.contains(flag), flags[flag] == nil, let value = rest.popFirst() else { return nil }
            flags[flag] = value
        }
        return flags
    }

    // A path, or - for stdin, so a long text never has to be quoted for the shell.
    static func text(at path: String) -> String? {
        let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : FileManager.default.contents(atPath: path)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    static func unreadable(_ path: String) -> Command.Reply {
        .failed(path == "-" ? "Nothing could be read from stdin.\n" : "\(path) could not be read.\n")
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]") + "\n"
    }
}

extension Command.Reply {
    static func refused(_ message: String?, else done: String) -> Command.Reply {
        message.map { .failed($0 + "\n") } ?? .ok(done)
    }
}
