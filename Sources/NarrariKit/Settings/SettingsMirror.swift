import Observation

// Read from the store each time and redrawn on any change, whoever wrote it, so no page keeps a copy that goes stale.
@MainActor
@Observable
public final class SettingsMirror {
    private var revision = 0
    @ObservationIgnored private let settings: SettingsStore

    public init(_ settings: SettingsStore) {
        self.settings = settings
        SettingsChanges.follow(SettingsChanges.settingKeys, by: self) { $0.revision += 1 }
    }

    // For readers that take the store, such as RemoteTranscriber.isSetUp; reading it counts as reading every setting.
    public var store: SettingsStore {
        _ = revision
        return settings
    }

    public subscript<Value>(_ setting: Setting<Value>) -> Value {
        get { store.value(setting) }
        set {
            settings.set(newValue, for: setting)
            revision += 1
        }
    }

    public subscript<Value: RawRepresentable>(_ setting: Setting<Value>) -> Value {
        get { store.value(setting) }
        set {
            settings.set(newValue, for: setting)
            revision += 1
        }
    }
}
