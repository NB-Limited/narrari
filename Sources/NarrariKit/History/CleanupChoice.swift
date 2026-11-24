import Foundation

// A row of the Clean up again list: a prompt, or the text as spoken with no clean-up.
public struct CleanupChoice: Sendable, Equatable {
    public static let asSpoken = CleanupChoice(prompt: nil)

    public let prompt: Prompt?

    public init(prompt: Prompt?) {
        self.prompt = prompt
    }

    public var title: String { prompt?.name ?? "As spoken" }

    public var runningLabel: String { prompt.map { "Cleaning up with \($0.name)" } ?? "Showing as spoken" }

    public var doneLabel: String { prompt.map { "Cleaned up with \($0.name)" } ?? "Shown as spoken" }

    // Whether this made the entry's text; a line written before the prompt was kept matches none.
    public func made(_ entry: HistoryEntry) -> Bool {
        guard let used = entry.prompt else { return false }
        let isCleaned = entry.cleanup.status == CleanupResult.Status.cleaned.rawValue
        guard let prompt else { return !isCleaned }
        return isCleaned && prompt.id == used
    }
}
