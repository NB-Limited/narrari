import Foundation

// Each command writes through the Settings page's own model, so it refuses what the window refuses, in its words.
public enum ShortcutsCommand: Sendable, Equatable {
    case list(asJSON: Bool)
    case set(String, to: String)
    case clear(String)

    static let mistake = "shortcuts takes [--json], set <action> <keys> or clear <action>."

    private static let actions: [(name: String, field: ShortcutsPageModel.ShortcutField)] = [
        ("dictation", .dictation), ("cleanup", .cleanupToggle), ("next-mode", .live(.mode)), ("paste-last", .live(.pasteLast)),
        ("meeting", .live(.meeting)), ("open-narrari", .live(.openWindow)), ("open-settings", .live(.openSettings))
    ]

    init?(_ arguments: [String]) {
        switch (arguments.first, arguments.count) {
        case (nil, _): self = .list(asJSON: false)
        case ("--json", 1): self = .list(asJSON: true)
        case ("set", 3...): self = .set(arguments[1], to: arguments.dropFirst(2).joined(separator: " "))
        case ("clear", 2): self = .clear(arguments[1])
        default: return nil
        }
    }

    @MainActor
    func run(in context: Command.Context) -> Command.Reply {
        let page = ShortcutsPageModel(settings: SettingsMirror(context.settings))
        switch self {
        case .list(let asJSON): return .ok(Self.list(page, asJSON: asJSON))
        case .set(let name, let keys):
            guard let field = Self.field(name) else { return Self.unknown(name) }
            return Self.set(field, named: name, to: keys, on: page, announce: context.announce)
        case .clear(let name):
            guard let field = Self.field(name) else { return Self.unknown(name) }
            guard case .live(let live) = field else {
                return .failed("\(name) can't be cleared, as on the Shortcuts page. Set other keys instead.\n")
            }
            page.clear(live)
            Self.keys(of: field).forEach(context.announce)
            return .ok("\(name) has no shortcut now.\n")
        }
    }

    @MainActor
    private static func set(
        _ field: ShortcutsPageModel.ShortcutField, named name: String, to keys: String, on page: ShortcutsPageModel,
        announce: (String) -> Void
    ) -> Command.Reply {
        if field == .dictation {
            guard let code = ShortcutText.modifierKey(keys) else {
                return .failed("\(keys) is not a key for dictation. Use one of \(ShortcutText.modifierKeyNames).\n")
            }
            page.record(modifierKey: code)
        } else {
            guard let shortcut = ShortcutText.shortcut(keys) else {
                return .failed("\(keys) is not a shortcut. Write modifiers and a key, such as ctrl+opt+m or ⌃⌥M.\n")
            }
            page.record(shortcut, for: field)
        }
        if let problem = page.shortcutErrors[field] { return .failed(problem + "\n") }
        self.keys(of: field).forEach(announce)
        return .ok("\(name) is now \(shown(field, on: page) ?? "None").\n")
    }

    @MainActor
    private static func list(_ page: ShortcutsPageModel, asJSON: Bool) -> String {
        let rows = actions.map { (action: $0.name, shortcut: shown($0.field, on: page)) }
        if asJSON { return SetupInput.json(rows.map { ["action": $0.action, "shortcut": $0.shortcut ?? ""] }) }
        return RecordKind.table(["ACTION", "SHORTCUT"], rows.map { [$0.action, $0.shortcut ?? "None"] })
    }

    @MainActor
    private static func shown(_ field: ShortcutsPageModel.ShortcutField, on page: ShortcutsPageModel) -> String? {
        switch field {
        case .dictation: page.hotkeyName
        case .cleanupToggle: HotkeyName.name(of: page.cleanupToggle)
        case .live(let live): page.liveShortcuts[live].map(HotkeyName.name(of:))
        }
    }

    private static func keys(of field: ShortcutsPageModel.ShortcutField) -> [String] {
        switch field {
        case .dictation: [DictationSettings.hotkeyKeyCode.key]
        case .cleanupToggle: [DictationSettings.cleanupToggleKeyCode.key, DictationSettings.cleanupToggleModifiers.key]
        case .live(let live): [live.keyCode.key, live.modifiers.key]
        }
    }

    private static func field(_ name: String) -> ShortcutsPageModel.ShortcutField? {
        actions.first { $0.name == name }?.field
    }

    private static func unknown(_ name: String) -> Command.Reply {
        .failed("\(name) is not a shortcut. The shortcuts are: \(actions.map(\.name).joined(separator: ", ")).\n")
    }
}
