import Foundation

public enum SummaryError: ProblemError, Equatable, CaseIterable {
    case emptyReply
    case wrongLanguage
    case tooShort
    case timedOut
    case tooLong
    case modelUnavailable
    case modelFailed
    case noTitle

    public var problem: Problem {
        switch self {
        case .emptyReply: Problem("summary.empty", "The model gave an empty summary. Try again, or choose another model.", canRetry: true)
        case .wrongLanguage:
            Problem("summary.wrong-language", "The summary came back in another language. Try again, or set the meeting's language.", canRetry: true)
        case .tooShort:
            Problem("summary.too-short", "The summary is too short for a meeting this long. Try again, or choose another model.", canRetry: true)
        case .timedOut: Problem("summary.timed-out", "The summary took too long. Try again, or choose a faster model.", canRetry: true)
        case .tooLong: Problem("summary.too-long", "The summary ran past its length limit. Try again, or use a template with fewer headings.", canRetry: true)
        case .modelUnavailable: Problem("summary.model-unavailable", "The model could not load. Try again, or choose another model.", canRetry: true)
        case .modelFailed: Problem("summary.model-failed", "The model stopped while writing. Try again, or choose another model.", canRetry: true)
        case .noTitle: Problem("summary.no-title", "The model gave no title. Type one.")
        }
    }
}
