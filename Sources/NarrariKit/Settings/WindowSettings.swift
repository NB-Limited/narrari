import Foundation

public enum WindowSettings {
    // A key code below 0 means no open-window hotkey. Modifiers are a Carbon mask, like the clean-up toggle's.
    public static let openHotkeyKeyCode = Setting("window.openHotkeyKeyCode", default: -1)
    public static let openHotkeyModifiers = Setting("window.openHotkeyModifiers", default: 0)
    public static let openSettingsHotkeyKeyCode = Setting("window.openSettingsHotkeyKeyCode", default: -1)
    public static let openSettingsHotkeyModifiers = Setting("window.openSettingsHotkeyModifiers", default: 0)
}
