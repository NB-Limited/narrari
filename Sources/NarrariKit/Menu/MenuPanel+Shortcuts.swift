import Foundation

extension MenuPanel {
    public var hotkey: String { HotkeyName.name(of: settings[DictationSettings.hotkeyKeyCode]) }

    // The shortcut that does the same from any app; Settings and Quit fall back to the panel's own keys. Nil for none.
    public func shortcut(for item: MenuPanelItem) -> String? {
        switch item {
        case .dictation: hotkey
        case .meeting: name(of: .meeting)
        case .openMain: name(of: .openWindow)
        case .settings: name(of: .openSettings) ?? "⌘,"
        case .quit: "⌘Q"
        default: nil
        }
    }

    private func name(of live: LiveShortcut) -> String? {
        live.shortcut(in: settings.store).map(HotkeyName.name(of:))
    }
}
