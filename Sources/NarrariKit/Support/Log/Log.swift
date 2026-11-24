import Foundation
import os

// Names are StaticString so dictated text can never be passed in and end up in the system log.
public enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.nb-limited.narrari.dev"
    private static let logger = Logger(subsystem: subsystem, category: "app")

    public static func timing(_ name: StaticString, seconds: Double) {
        logger.notice("timing \(name.description, privacy: .public) \(seconds, format: .fixed(precision: 3), privacy: .public)s")
    }

    public static func count(_ name: StaticString, _ value: Int) {
        logger.notice("count \(name.description, privacy: .public) \(value, privacy: .public)")
    }

    public static func event(_ name: StaticString) {
        logger.notice("event \(name.description, privacy: .public)")
    }

    // An error without a problem logs its domain and number, which are fixed; never its description, which can hold a path or a name.
    public static func failure(_ kind: StaticString, error: (any Error)? = nil) {
        let type = error.map { String(reflecting: Swift.type(of: $0)) } ?? "none"
        let detail = switch error {
        case nil: ""
        case let error as any ProblemError: " \(error.problem.code)" + (error.status.map { " status \($0)" } ?? "")
        case let error?: " \((error as NSError).domain) \((error as NSError).code)"
        }
        logger.error("failure \(kind.description, privacy: .public) \(type, privacy: .public)\(detail, privacy: .public)")
    }
}
