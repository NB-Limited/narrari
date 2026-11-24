import AppKit
import Carbon.HIToolbox

// `modifiers` is a Carbon mask plus, for a right-only modifier, its bit moved up 8, which versions before sides ignore.
public struct Shortcut: Sendable, Equatable {
    public let keyCode: Int
    public let modifiers: Int

    struct Modifier: Sendable {
        let carbon: Int
        let flag: NSEvent.ModifierFlags
        let symbol: String
        let leftDevice: UInt
        let rightDevice: UInt
    }

    static let flags = [
        Modifier(carbon: controlKey, flag: .control, symbol: "⌃", leftDevice: 0x01, rightDevice: 0x2000),
        Modifier(carbon: optionKey, flag: .option, symbol: "⌥", leftDevice: 0x20, rightDevice: 0x40),
        Modifier(carbon: shiftKey, flag: .shift, symbol: "⇧", leftDevice: 0x02, rightDevice: 0x04),
        Modifier(carbon: cmdKey, flag: .command, symbol: "⌘", leftDevice: 0x08, rightDevice: 0x10)
    ]
    private static let rightSideShift = 8
    private static let kinds: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // A modifier pressed only on the right is recorded as right-only; one pressed on the left, or both, works from either side.
    public init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.keyCode = Int(keyCode)
        modifiers = Self.flags.filter { flags.contains($0.flag) }.reduce(0) { mask, modifier in
            let isRightOnly = flags.rawValue & modifier.rightDevice != 0 && flags.rawValue & modifier.leftDevice == 0
            return mask | modifier.carbon | (isRightOnly ? modifier.carbon << Self.rightSideShift : 0)
        }
    }

    public var carbonModifiers: Int { modifiers & 0xFFFF }

    public var isSided: Bool { modifiers > 0xFFFF }

    func has(_ carbon: Int) -> Bool { modifiers & carbon != 0 }

    func isRightOnly(_ carbon: Int) -> Bool { modifiers & (carbon << Self.rightSideShift) != 0 }

    static func mask(_ carbon: Int, isRightOnly: Bool) -> Int { carbon | (isRightOnly ? carbon << rightSideShift : 0) }

    // Shift alone with a letter is typing, not a shortcut.
    public var hasCommandOptionOrControl: Bool {
        carbonModifiers & (cmdKey | optionKey | controlKey) != 0
    }

    public var isEscape: Bool { keyCode == kVK_Escape }

    public func clashes(with other: Shortcut) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }

    // Exactly these modifiers, as Carbon matches them, or these plus `extra`, the dictation key held for the clean-up toggle.
    public func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags, alsoWith extra: NSEvent.ModifierFlags = []) -> Bool {
        guard Int(keyCode) == self.keyCode else { return false }
        let pressed = flags.intersection(Self.kinds)
        let required = NSEvent.ModifierFlags(Self.flags.filter { has($0.carbon) }.map(\.flag))
        guard pressed == required || pressed == required.union(extra) else { return false }
        return Self.flags.allSatisfy { !isRightOnly($0.carbon) || flags.rawValue & $0.rightDevice != 0 }
    }
}
