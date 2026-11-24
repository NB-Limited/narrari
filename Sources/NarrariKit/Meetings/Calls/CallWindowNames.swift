import Foundation

// One element of a call app's window tree, as the Accessibility interface shows it.
public struct WindowElement: Sendable, Equatable {
    public let role: String
    public let title: String
    public let value: String
    public let label: String
    public let children: [WindowElement]

    public init(role: String, title: String = "", value: String = "", label: String = "", children: [WindowElement] = []) {
        self.role = role
        self.title = title
        self.value = value
        self.label = label
        self.children = children
    }
}

// A running app's windows by bundle id. Without access or without the app there are no windows, no error and no prompt.
public protocol CallWindowSource: Sendable {
    func windows(of app: String) async -> [WindowElement]
    // The switch some apps need before they build their tree for assistive tools.
    func assistiveMode(of app: String) async -> Bool
    func setAssistiveMode(_ isOn: Bool, of app: String) async
}

// One call app's participant list, from the shape of its windows.
protocol CallWindowReader: Sendable {
    var apps: [String] { get }
    var needsAssistiveMode: Bool { get }
    // Logged once a meeting when the app had windows but no list was ever found in them.
    var unread: StaticString { get }
    // Each person's text as shown, labels included; nil when no participant list is found.
    func names(in windows: [WindowElement]) -> [String]?
}

// The people a call app shows in its windows, read at once and every 30 seconds while the meeting records, only with
// the switch on. They are personal data: never logged.
@MainActor
public final class CallWindowNames {
    private static let interval: Duration = .seconds(30)
    private static let readers: [any CallWindowReader] = [ZoomWindowReader(), TeamsWindowReader()]
    private static let labels: Set<String> = ["host", "co-host", "guest", "me", "you", "organizer", "organiser", "presenter"]
    private static let ownLabels: Set<String> = ["me", "you"]

    private let source: any CallWindowSource
    private let settings: SettingsStore
    private let clock: any Clock<Duration>
    private let ownerName: String
    private var reading: Task<Void, Never>?

    public init(source: any CallWindowSource, settings: SettingsStore, clock: any Clock<Duration>, ownerName: String) {
        self.source = source
        self.settings = settings
        self.clock = clock
        self.ownerName = ownerName
    }

    public func start(app: String, found: @escaping @MainActor ([String]) async -> Void) {
        guard let reader = Self.readers.first(where: { $0.apps.contains(app) }) else { return }
        let previous = reading
        reading = Task {
            await previous?.value
            await follow(app, with: reader, found)
        }
    }

    // Returns once the last read is over and the app's assistive mode is back as it was.
    public func stop() async {
        let reading = reading
        self.reading = nil
        reading?.cancel()
        await reading?.value
    }

    private func follow(_ app: String, with reader: any CallWindowReader, _ found: @MainActor ([String]) async -> Void) async {
        var wasAssistive: Bool?
        var listed: Bool?
        repeat {
            guard settings.value(MeetingsSettings.readsCallWindowNames) else { continue }
            if reader.needsAssistiveMode, wasAssistive == nil {
                let isOn = await source.assistiveMode(of: app)
                wasAssistive = isOn
                if !isOn { await source.setAssistiveMode(true, of: app) }
            }
            let windows = await source.windows(of: app)
            guard !windows.isEmpty else { continue }
            guard let texts = reader.names(in: windows) else {
                listed = listed ?? false
                continue
            }
            listed = true
            let names = texts.compactMap(person)
            if !names.isEmpty { await found(names) }
        } while (try? await clock.sleep(for: Self.interval)) != nil
        if wasAssistive == false { await source.setAssistiveMode(false, of: app) }
        if listed == false { Log.event(reader.unread) }
    }

    // "Ana Petrova (Host)" is Ana Petrova; a name labelled "me" or "You", or the owner's own, is the owner.
    private func person(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            let tags = name[open.upperBound..<name.index(before: name.endIndex)].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if tags.allSatisfy(Self.labels.contains) {
                guard !tags.contains(where: Self.ownLabels.contains) else { return nil }
                name = String(name[..<open.lowerBound])
            }
        }
        guard !name.isEmpty, name.caseInsensitiveCompare(ownerName) != .orderedSame else { return nil }
        return name
    }
}

extension WindowElement {
    func first(where isMatch: (WindowElement) -> Bool) -> WindowElement? {
        if isMatch(self) { return self }
        for child in children {
            if let found = child.first(where: isMatch) { return found }
        }
        return nil
    }

    func starts(with marker: String) -> Bool {
        title.hasPrefix(marker) || label.hasPrefix(marker)
    }

    // The first text of every row below this element, a row holding other rows being a section, not a person; nil with no rows.
    var rowTexts: [String]? {
        var rows: [WindowElement] = []
        collectRows(into: &rows)
        let people = rows.filter { row in !row.children.contains { $0.first { $0.role == Self.row } != nil } }
        guard !people.isEmpty else { return nil }
        return people.compactMap { row in
            row.first { $0.role == Self.text && !$0.value.isEmpty }?.value
        }
    }

    private static let row = "AXRow"
    private static let text = "AXStaticText"

    private func collectRows(into rows: inout [WindowElement]) {
        for child in children {
            if child.role == Self.row { rows.append(child) }
            child.collectRows(into: &rows)
        }
    }
}
