import Foundation

public struct Problem: Sendable, Hashable {
    // Fixed once shipped: meeting files store it and the log prints it, so it never holds a person's words.
    public let code: String
    public let message: String
    public let canRetry: Bool

    public init(_ code: String, _ message: String, canRetry: Bool = false) {
        self.code = code
        self.message = message
        self.canRetry = canRetry
    }

    // Beside its own Try again button the message leaves out the words that say the same; elsewhere it stays whole.
    public var besideRetry: String {
        guard canRetry else { return message }
        for (ending, rest) in [(" Try again.", ""), (", then try again.", "."), (" and try again.", ".")] where message.hasSuffix(ending) {
            return message.dropLast(ending.count) + rest
        }
        return message
    }
}

public protocol ProblemError: Error {
    var problem: Problem { get }
    // A number the system gave, such as an HTTP or OSStatus code, for the log only.
    var status: Int? { get }
}

extension ProblemError {
    public var status: Int? { nil }
}

extension Error {
    // The feature's fixed problem stands in for an error without one, so system text never reaches the screen or a file.
    public func problem(or fallback: Problem) -> Problem {
        (self as? any ProblemError)?.problem ?? fallback
    }
}
