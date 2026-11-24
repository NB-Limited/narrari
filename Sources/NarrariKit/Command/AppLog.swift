import Foundation

// Narrari's lines in the system log, read through /usr/bin/log, the one reader macOS gives a process without an entitlement.
enum AppLog {
    struct Line: Sendable, Equatable, Decodable {
        let timestamp: String
        let processID: Int
        let eventMessage: String

        var text: String { "\(timestamp) \(processID) \(eventMessage)" }
    }

    static func show(last: String) -> Command.Reply {
        switch read(["--last", last], matching: "") {
        case .success(let lines): .ok(lines.map { $0.text + "\n" }.joined())
        case .failure(let problem): .failed(problem.message)
        }
    }

    // `extra` narrows the subsystem's lines further; the arguments choose the time.
    static func read(_ window: [String], matching extra: String) -> Result<[Line], ReadProblem> {
        var predicate = "subsystem == \"\(Log.subsystem)\""
        if !extra.isEmpty { predicate += " AND \(extra)" }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/log")
        process.arguments = ["show", "--style", "ndjson", "--predicate", predicate] + window
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(ReadProblem(message: "The log could not be read: /usr/bin/log did not start.\n"))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reason = (String(bytes: errorData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(ReadProblem(message: "The log could not be read: \(reason)\n"))
        }
        return .success(lines(in: data))
    }

    // The last line of the output only counts the others, so it fails to decode and is left out like any stray line.
    static func lines(in data: Data) -> [Line] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Line.self, from: Data($0)) }
    }

    struct ReadProblem: Error {
        let message: String
    }
}
