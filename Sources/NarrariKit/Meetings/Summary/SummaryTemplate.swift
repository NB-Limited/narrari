import Foundation

public enum SummaryTemplateError: ProblemError, Equatable, CaseIterable {
    case empty
    case headingWithoutInstruction
    case noHeadings
    case missing

    public var problem: Problem {
        switch self {
        case .empty: Problem("template.empty", "The summary template is empty. Write its headings in Settings, Summaries.", canRetry: true)
        case .headingWithoutInstruction:
            Problem("template.no-instruction", "A heading in the summary template has nothing under it. Fix it in Settings, Summaries.", canRetry: true)
        case .noHeadings: Problem("template.no-headings", "The summary template has no headings. Start each with # in Settings, Summaries.", canRetry: true)
        case .missing: Problem("template.missing", "The summary template is gone. Choose another, then try again.", canRetry: true)
        }
    }
}

// A template file: its name on the first line, then each heading on a line starting with # and its instruction below it.
public struct SummaryTemplate: Sendable, Equatable, Identifiable {
    public struct Section: Sendable, Equatable {
        public let heading: String
        public let instruction: String
    }

    public let id: String
    public let name: String
    public let sections: [Section]
    // Everything under the name line, as written, for the editor.
    public let text: String

    public init(id: String, markdown: String) throws {
        var lines = markdown.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw SummaryTemplateError.empty }
        let name = Self.stripped(lines.removeFirst())
        var sections: [Section] = []
        var heading: String?
        var instruction: [String] = []
        func close() throws {
            guard let heading else { return }
            guard !instruction.isEmpty else { throw SummaryTemplateError.headingWithoutInstruction }
            sections.append(Section(heading: heading, instruction: instruction.joined(separator: " ")))
        }
        for line in lines {
            if line.hasPrefix("#") {
                try close()
                heading = Self.stripped(line)
                instruction = []
            } else if heading != nil {
                instruction.append(line)
            }
        }
        try close()
        guard !sections.isEmpty else { throw SummaryTemplateError.noHeadings }
        self.id = id
        self.name = name.isEmpty ? id : name
        self.sections = sections
        let afterName = markdown.drop { $0.isWhitespace }.drop { !$0.isNewline }
        text = afterName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var headings: String {
        sections.map(\.heading).joined(separator: ", ")
    }

    // The file as written: the name on the first line, the headings and instructions under it.
    public static func markdown(name: String, text: String) -> String {
        "\(name)\n\n\(text)\n"
    }

    private static func stripped(_ line: String) -> String {
        String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }
}
