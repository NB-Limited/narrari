import AppKit

// What the key tap does with one key event: the shortcuts with a side are matched here, since Carbon cannot tell sides apart.
public struct SidedShortcuts: Sendable {
    public enum Target: Sendable, Equatable {
        case live(LiveShortcut)
        case cleanupToggle
    }

    public struct Entry: Sendable {
        public let shortcut: Shortcut
        public let target: Target
        public let alsoWith: NSEvent.ModifierFlags

        public init(_ shortcut: Shortcut, _ target: Target, alsoWith: NSEvent.ModifierFlags = []) {
            self.shortcut = shortcut
            self.target = target
            self.alsoWith = alsoWith
        }
    }

    public enum Decision: Sendable, Equatable {
        case pass
        case swallow
        case fire(Target)
    }

    public var entries: [Entry]
    private var heldKeys: Set<UInt16> = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    // A matched key fires once, also from a repeat when the modifier came after the key, and is swallowed down, repeat
    // and up, so the front app never sees it with the modifier.
    public mutating func decide(isDown: Bool, keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> Decision {
        guard isDown else { return heldKeys.remove(keyCode) == nil ? .pass : .swallow }
        if isRepeat, heldKeys.contains(keyCode) { return .swallow }
        guard let entry = entries.first(where: { $0.shortcut.matches(keyCode: keyCode, flags: flags, alsoWith: $0.alsoWith) }) else {
            heldKeys.remove(keyCode)
            return .pass
        }
        heldKeys.insert(keyCode)
        return .fire(entry.target)
    }

    public func claims(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        entries.contains { $0.shortcut.matches(keyCode: keyCode, flags: flags, alsoWith: $0.alsoWith) }
    }
}
