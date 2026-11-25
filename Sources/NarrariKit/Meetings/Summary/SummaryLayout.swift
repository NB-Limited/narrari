import Foundation

// A summary as the page shows and copies it: the model's bold marks dropped and every list marker a "- ".
public enum SummaryLayout {
    public static func plain(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(line).joined(separator: "\n")
    }

    private static func line(_ raw: Substring) -> String {
        let line = raw.replacingOccurrences(of: "**", with: "")
        let trimmed = line.drop(while: \.isWhitespace)
        guard let marker = trimmed.first, "*•-".contains(marker), trimmed.dropFirst().first?.isWhitespace == true else { return line }
        return "- " + trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}
