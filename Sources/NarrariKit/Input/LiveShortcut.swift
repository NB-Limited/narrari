import Foundation

// The shortcuts that work whenever Narrari runs, unlike Escape and the clean-up toggle, which work only while dictating.
public enum LiveShortcut: CaseIterable, Sendable {
    case mode
    case openWindow
    case pasteLast
    case meeting
    case openSettings

    public var keyCode: Setting<Int> {
        switch self {
        case .mode: ModeSettings.hotkeyKeyCode
        case .openWindow: WindowSettings.openHotkeyKeyCode
        case .pasteLast: DictationSettings.pasteLastKeyCode
        case .meeting: MeetingsSettings.hotkeyKeyCode
        case .openSettings: WindowSettings.openSettingsHotkeyKeyCode
        }
    }

    public var modifiers: Setting<Int> {
        switch self {
        case .mode: ModeSettings.hotkeyModifiers
        case .openWindow: WindowSettings.openHotkeyModifiers
        case .pasteLast: DictationSettings.pasteLastModifiers
        case .meeting: MeetingsSettings.hotkeyModifiers
        case .openSettings: WindowSettings.openSettingsHotkeyModifiers
        }
    }

    // Nil when cleared: the settings keep a key code below 0.
    public func shortcut(in settings: SettingsStore) -> Shortcut? {
        let code = settings.value(keyCode)
        guard code >= 0 else { return nil }
        return Shortcut(keyCode: code, modifiers: settings.value(modifiers))
    }

    public func store(_ shortcut: Shortcut?, in settings: SettingsStore) {
        settings.set(shortcut?.keyCode ?? -1, for: keyCode)
        settings.set(shortcut?.modifiers ?? 0, for: modifiers)
    }
}

extension Shortcut {
    public static func cleanupToggle(in settings: SettingsStore) -> Shortcut {
        Shortcut(
            keyCode: settings.value(DictationSettings.cleanupToggleKeyCode),
            modifiers: settings.value(DictationSettings.cleanupToggleModifiers)
        )
    }
}
