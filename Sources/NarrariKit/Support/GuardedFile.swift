import AppKit
import Observation

// A settings file a page edits. Once it fails to parse, the page writes nothing until it is fixed or moved aside,
// so what was in it is never lost.
@MainActor
@Observable
public final class GuardedFile {
    public private(set) var isUnreadable = false
    public private(set) var moveError: String?

    public let url: URL
    @ObservationIgnored private let now: () -> Date

    private static let stamp: Date.FormatString = """
        \(year: .padded(4))\(month: .twoDigits)\(day: .twoDigits)-\
        \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)
        """

    public init(url: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    public var name: String { url.lastPathComponent }

    public static func saveError(_ contents: String) -> String {
        "Your \(contents) could not be saved. Check that the Narrari folder in Application Support can be written to."
    }

    // Nil when the file could not be parsed; the page then shows the defaults it already holds.
    func read<Value>(_ failure: StaticString, _ load: () throws -> Value) -> Value? {
        do {
            let value = try load()
            isUnreadable = false
            return value
        } catch {
            Log.failure(failure, error: error)
            isUnreadable = true
            return nil
        }
    }

    // Renames the file to <name>.unreadable-<time>.json beside it; only then may the page write a new one.
    public func startFresh() {
        let style = Date.VerbatimFormatStyle(
            format: Self.stamp, locale: Locale(identifier: "en_US_POSIX"), timeZone: .autoupdatingCurrent, calendar: Calendar(identifier: .gregorian)
        )
        let stem = url.deletingPathExtension().lastPathComponent
        let aside = url.deletingLastPathComponent().appending(path: "\(stem).unreadable-\(now().formatted(style)).\(url.pathExtension)")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            Log.event("store-moved-aside")
            isUnreadable = false
            moveError = nil
        } catch {
            Log.failure("store-move-aside", error: error)
            moveError = "\(name) could not be renamed. Move it out of the folder in Finder, then open this page again."
        }
    }

    public func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
