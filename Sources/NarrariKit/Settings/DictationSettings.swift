import Foundation

public enum DictationSettings {
    public static let hotkeyKeyCode = Setting("dictation.hotkeyKeyCode", default: 54)
    public static let cleanupToggleKeyCode = Setting("dictation.cleanupToggleKeyCode", default: 14)
    // A Carbon modifier mask, see Shortcut; 256 is Command, so the default toggle is Command E.
    public static let cleanupToggleModifiers = Setting("dictation.cleanupToggleModifiers", default: 256)
    // A key code below 0 means no paste-last hotkey; 6144 is Control Option, so the default is Control Option V.
    public static let pasteLastKeyCode = Setting("dictation.pasteLastKeyCode", default: 9)
    public static let pasteLastModifiers = Setting("dictation.pasteLastModifiers", default: 6144)
    public static let holdThreshold = Setting("dictation.holdThreshold", default: 0.5)
    public static let shortcutWindow = Setting("dictation.shortcutWindow", default: 0.2)
    public static let minimumRecording = Setting("dictation.minimumRecording", default: 0.3)
    public static let clipboardRestoreDelay = Setting("dictation.clipboardRestoreDelay", default: 1.0)
    public static let mutesOutput = Setting("dictation.mutesOutput", default: true)
    public static let playsSounds = Setting("dictation.playsSounds", default: true)
    public static let soundSet = Setting("dictation.soundSet", default: SoundSet.standard)
    public static let showsLiveText = Setting("dictation.showsLiveText", default: true)
    // An empty UID means the system default microphone, and no output muted by Narrari.
    public static let microphoneUID = Setting("dictation.microphoneUID", default: "")
    public static let prefersBuiltInOverBluetooth = Setting("dictation.prefersBuiltInOverBluetooth", default: true)
    public static let mutedOutputUID = Setting("dictation.mutedOutputUID", default: "")
}
