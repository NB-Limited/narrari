import Foundation

public enum ModeSettings {
    // A key code below 0 means no mode hotkey. Modifiers are a Carbon mask, like the clean-up toggle's.
    public static let hotkeyKeyCode = Setting("mode.hotkeyKeyCode", default: -1)
    public static let hotkeyModifiers = Setting("mode.hotkeyModifiers", default: 0)
}
