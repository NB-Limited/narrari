import Foundation

// Every setting, for the narrari command. scripts/check.sh fails when a Setting in a *Settings enum is missing here.
public enum SettingsList {
    public static let all: [any ListedSetting] = [
        CleanupSettings.isEnabled,
        CleanupSettings.usesTriggers,
        CleanupSettings.skippedLanguages,
        CleanupSettings.engine,
        CleanupSettings.localModel,
        CleanupSettings.chatTimeLimit,
        CleanupSettings.idleLimit,
        CleanupSettings.chatAddress,
        CleanupSettings.chatModel,
        DictationSettings.hotkeyKeyCode,
        DictationSettings.cleanupToggleKeyCode,
        DictationSettings.cleanupToggleModifiers,
        DictationSettings.pasteLastKeyCode,
        DictationSettings.pasteLastModifiers,
        DictationSettings.holdThreshold,
        DictationSettings.shortcutWindow,
        DictationSettings.minimumRecording,
        DictationSettings.clipboardRestoreDelay,
        DictationSettings.mutesOutput,
        DictationSettings.playsSounds,
        DictationSettings.soundSet,
        DictationSettings.showsLiveText,
        DictationSettings.microphoneUID,
        DictationSettings.prefersBuiltInOverBluetooth,
        DictationSettings.mutedOutputUID,
        DictionarySettings.writesSpokenMarks,
        GeneralSettings.followsReduceMotion,
        HistorySettings.retentionDays,
        MeetingsSettings.startsByItself,
        MeetingsSettings.stopsWithCall,
        MeetingsSettings.usesVoiceMemory,
        MeetingsSettings.summaryTemplate,
        MeetingsSettings.showsLiveText,
        MeetingsSettings.summaryModel,
        MeetingsSettings.bar,
        MeetingsSettings.readsCallWindowNames,
        MeetingsSettings.ignoredApps,
        MeetingsSettings.ownNames,
        MeetingsSettings.audioRetentionDays,
        MeetingsSettings.hotkeyKeyCode,
        MeetingsSettings.hotkeyModifiers,
        MeetingsSettings.systemAudio,
        ModeSettings.hotkeyKeyCode,
        ModeSettings.hotkeyModifiers,
        PillSettings.look,
        PillSettings.colour,
        SpeechSettings.localModel,
        SpeechSettings.usesRemote,
        SpeechSettings.remoteAddress,
        SpeechSettings.remoteModel,
        SpeechSettings.remoteLanguage,
        SpeechSettings.remoteSizeLimitBytes,
        SpeechSettings.remoteTimeLimit,
        WindowSettings.openHotkeyKeyCode,
        WindowSettings.openHotkeyModifiers,
        WindowSettings.openSettingsHotkeyKeyCode,
        WindowSettings.openSettingsHotkeyModifiers
    ]

    public static func setting(_ key: String) -> (any ListedSetting)? {
        all.first { $0.key == key }
    }
}

// A setting read and written as text, whatever its type.
public protocol ListedSetting: Sendable {
    var key: String { get }
    var defaultText: String { get }
    var allowed: String { get }
    func text(in settings: SettingsStore) -> String
    // False when the text is not a value of this setting.
    func set(_ text: String, in settings: SettingsStore) -> Bool
    func reset(in settings: SettingsStore)
}

extension Setting: ListedSetting where Value: SettingValue {
    public var defaultText: String { defaultValue.settingText }
    public var allowed: String { Value.allowed }

    public func text(in settings: SettingsStore) -> String {
        Value.read(self, in: settings).settingText
    }

    public func set(_ text: String, in settings: SettingsStore) -> Bool {
        guard let value = Value(settingText: text) else { return false }
        Value.write(value, for: self, in: settings)
        return true
    }

    public func reset(in settings: SettingsStore) {
        settings.reset(self)
    }
}

public protocol SettingValue: Sendable {
    init?(settingText: String)
    var settingText: String { get }
    static var allowed: String { get }
    static func read(_ setting: Setting<Self>, in settings: SettingsStore) -> Self
    static func write(_ value: Self, for setting: Setting<Self>, in settings: SettingsStore)
}

extension SettingValue {
    public static func read(_ setting: Setting<Self>, in settings: SettingsStore) -> Self {
        settings.value(setting)
    }

    public static func write(_ value: Self, for setting: Setting<Self>, in settings: SettingsStore) {
        settings.set(value, for: setting)
    }
}

// A choice is stored by its name, so it goes through the store's RawRepresentable methods, never the plain ones.
extension SettingValue where Self: RawRepresentable & CaseIterable, RawValue == String {
    public init?(settingText: String) {
        self.init(rawValue: settingText)
    }

    public var settingText: String { rawValue }

    public static var allowed: String { "one of " + allCases.map(\.rawValue).joined(separator: ", ") }

    public static func read(_ setting: Setting<Self>, in settings: SettingsStore) -> Self {
        settings.value(setting)
    }

    public static func write(_ value: Self, for setting: Setting<Self>, in settings: SettingsStore) {
        settings.set(value, for: setting)
    }
}

extension Bool: SettingValue {
    public init?(settingText: String) {
        switch settingText {
        case "true": self = true
        case "false": self = false
        default: return nil
        }
    }

    public var settingText: String { self ? "true" : "false" }
    public static var allowed: String { "true or false" }
}

extension Int: SettingValue {
    public init?(settingText: String) {
        self.init(settingText)
    }

    public var settingText: String { String(self) }
    public static var allowed: String { "a whole number" }
}

extension Double: SettingValue {
    public init?(settingText: String) {
        guard let value = Double(settingText), value.isFinite else { return nil }
        self = value
    }

    public var settingText: String { String(self) }
    public static var allowed: String { "a number, such as 0.5" }
}

extension String: SettingValue {
    public init?(settingText: String) {
        self = settingText
    }

    public var settingText: String { self }
    public static var allowed: String { "any text" }
}

extension Array: SettingValue where Element == String {
    public init?(settingText: String) {
        self = settingText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public var settingText: String { joined(separator: ",") }
    public static var allowed: String { "names separated by commas, such as bg,ru, or nothing for none" }
}

extension CleanupEngineKind: SettingValue {}
extension MeetingBar: SettingValue {}
extension ParakeetModel: SettingValue {}
extension Permissions.SystemAudio: SettingValue {}
extension PillColour: SettingValue {}
extension PillLook: SettingValue {}
extension SoundSet: SettingValue {}
