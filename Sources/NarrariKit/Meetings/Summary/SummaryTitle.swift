import Foundation

// A meeting's title, asked of the model that wrote its summary and read from the summary; the reply is tidied here, not trusted.
enum SummaryTitle {
    static let growth = ReplyGrowth(factor: 0, extra: 40)
    static let mostWords = 10
    static let mostCharacters = 80
    static let timeLimit: Duration = .seconds(30)
    private static let marks = CharacterSet(charactersIn: "\"'“”„‟«»‘’‚‹›「」『』*_`#").union(.whitespaces)

    // Nil when the reply leaves nothing to use.
    static func make(with engine: any CleanupEngine, from summary: String, in language: String?) async throws -> String? {
        cleaned(try await engine.rewrite(summary, instruction: instruction(language), growth: growth))
    }

    static func instruction(_ language: String?) -> String {
        let written = language.map { " in \($0)" } ?? ""
        return "The user message is the summary of a meeting. Write a short title for the meeting\(written), three to seven words. "
            + "Reply with the title only."
    }

    // The first line with words, without quotes, markdown or a closing full stop, cut to ten words.
    static func cleaned(_ reply: String) -> String? {
        let lines = reply.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: marks) }
        guard let line = lines.first(where: { !$0.isEmpty })?.replacingOccurrences(of: "**", with: "") else { return nil }
        var words = line.split(whereSeparator: \.isWhitespace).prefix(mostWords).joined(separator: " ")
        while words.count > mostCharacters, let space = words.lastIndex(of: " ") { words = String(words[..<space]) }
        let title = String(words.prefix(mostCharacters)).trimmingCharacters(in: CharacterSet(charactersIn: ".。").union(marks))
        return title.isEmpty ? nil : title
    }
}
