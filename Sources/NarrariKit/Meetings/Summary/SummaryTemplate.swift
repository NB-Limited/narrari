import Foundation

public struct SummaryTemplateError: LocalizedError, Equatable {
    public let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
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
        guard !lines.isEmpty else { throw SummaryTemplateError("The template \(id) is empty.") }
        let name = Self.stripped(lines.removeFirst())
        var sections: [Section] = []
        var heading: String?
        var instruction: [String] = []
        func close() throws {
            guard let heading else { return }
            guard !instruction.isEmpty else { throw SummaryTemplateError("The heading \(heading) in the template \(id) has no instruction.") }
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
        guard !sections.isEmpty else { throw SummaryTemplateError("The template \(id) has no headings.") }
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
