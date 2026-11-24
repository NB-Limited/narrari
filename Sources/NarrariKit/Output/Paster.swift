import AppKit
import Carbon.HIToolbox

public struct PasteboardEntry: Sendable, Equatable {
    public let type: NSPasteboard.PasteboardType
    public let data: Data

    public init(type: NSPasteboard.PasteboardType, data: Data) {
        self.type = type
        self.data = data
    }
}

@MainActor
public protocol Pasteboard: AnyObject {
    var changeCount: Int { get }
    func items() -> [[PasteboardEntry]]
    @discardableResult func replace(with items: [[PasteboardEntry]]) -> Int
}

@MainActor
public final class SystemPasteboard: Pasteboard {
    private let pasteboard = NSPasteboard.general

    public init() {}

    public var changeCount: Int { pasteboard.changeCount }

    public func items() -> [[PasteboardEntry]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { PasteboardEntry(type: type, data: $0) }
            }
        }
    }

    public func replace(with items: [[PasteboardEntry]]) -> Int {
        pasteboard.clearContents()
        let objects = items.map { entries in
            let item = NSPasteboardItem()
            entries.forEach { item.setData($0.data, forType: $0.type) }
            return item
        }
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
        return pasteboard.changeCount
    }
}

// Every outcome but pasted leaves the text on the clipboard, so Command V still gets it.
public enum PasteOutcome: Sendable, Equatable {
    case pasted
    case copiedAccessibilityOff
    case copiedKeystrokeFailed
}

@MainActor
public final class Paster {
    // nspasteboard.org markers, so clipboard managers skip the temporary text.
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static let modifierPoll = Duration.milliseconds(20)
    private static let modifierPolls = 50

    private let pasteboard: any Pasteboard
    private let access: InputAccess
    private let settings: SettingsStore
    private let postPaste: @MainActor () -> Bool
    private let clock: any Clock<Duration>
    private var restoring: Task<Void, Never>?
    private var saved: (changeCount: Int, items: [[PasteboardEntry]])?

    public init(
        pasteboard: any Pasteboard = SystemPasteboard(),
        access: InputAccess = .system,
        settings: SettingsStore,
        postPaste: @escaping @MainActor () -> Bool = Paster.postCommandV,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.pasteboard = pasteboard
        self.access = access
        self.settings = settings
        self.postPaste = postPaste
        self.clock = clock
    }

    // Reading every type makes other apps render their promised data, so this runs while the user still speaks.
    // The count is read first, so a copy made during the read makes the paste read again.
    public func saveClipboard() {
        saved = (pasteboard.changeCount, pasteboard.items())
    }

    public func paste(_ text: String) async -> PasteOutcome {
        let keysUp = access.isAccessibilityGranted() ? await waitForModifiersUp() : true
        await finishRestore()
        let early = saved
        saved = nil
        let textEntry = PasteboardEntry(type: .string, data: Data(text.utf8))

        guard access.isAccessibilityGranted() else {
            pasteboard.replace(with: [[textEntry]])
            return .copiedAccessibilityOff
        }

        let earlier: [[PasteboardEntry]]
        if let early, early.changeCount == pasteboard.changeCount {
            earlier = early.items
        } else {
            earlier = pasteboard.items()
        }
        let written = pasteboard.replace(with: [[
            textEntry,
            PasteboardEntry(type: Self.transientType, data: Data()),
            PasteboardEntry(type: Self.concealedType, data: Data())
        ]])
        guard keysUp, postPaste() else {
            Log.failure("paste-keystroke")
            pasteboard.replace(with: [[textEntry]])
            return .copiedKeystrokeFailed
        }

        let delay = settings.value(DictationSettings.clipboardRestoreDelay)
        restoring = Task { [clock] in
            try? await clock.sleep(for: .seconds(delay))
            // Something copied after the paste is newer than what was saved, so it stays.
            if pasteboard.changeCount == written { pasteboard.replace(with: earlier) }
        }
        return .pasted
    }

    // Keys still held from a shortcut would join Command V, and the app in front would ignore it. False when they stay held.
    private func waitForModifiersUp() async -> Bool {
        var polls = 0
        while access.modifiersHeld() {
            guard polls < Self.modifierPolls else {
                Log.event("paste-modifiers-still-held")
                return false
            }
            try? await clock.sleep(for: Self.modifierPoll)
            polls += 1
        }
        return true
    }

    // A second paste waiting here may find a newer restore scheduled by the first, so it waits for that one too.
    public func finishRestore() async {
        while let pending = restoring {
            await pending.value
            if restoring == pending { restoring = nil }
        }
    }

    // False when the keystroke could not be made, so nothing was posted.
    public static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let events = [true, false].compactMap { CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: $0) }
        guard events.count == 2 else { return false }
        for event in events {
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
