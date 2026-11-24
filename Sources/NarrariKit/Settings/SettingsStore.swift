import Foundation

public struct Setting<Value: Sendable>: Sendable {
    public let key: String
    public let defaultValue: Value

    public init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

// UserDefaults is documented as thread-safe but not marked Sendable in the SDK.
public struct SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore(defaults: .standard)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func value<Value>(_ setting: Setting<Value>) -> Value {
        defaults.object(forKey: setting.key) as? Value ?? setting.defaultValue
    }

    public func value<Value: RawRepresentable>(_ setting: Setting<Value>) -> Value {
        (defaults.object(forKey: setting.key) as? Value.RawValue).flatMap(Value.init(rawValue:)) ?? setting.defaultValue
    }

    public func hasValue<Value>(for setting: Setting<Value>) -> Bool {
        defaults.object(forKey: setting.key) != nil
    }

    public func set<Value>(_ value: Value, for setting: Setting<Value>) {
        defaults.set(value, forKey: setting.key)
        SettingsChanges.post(setting.key)
    }

    public func set<Value: RawRepresentable>(_ value: Value, for setting: Setting<Value>) {
        defaults.set(value.rawValue, forKey: setting.key)
        SettingsChanges.post(setting.key)
    }

    public func reset<Value>(_ setting: Setting<Value>) {
        defaults.removeObject(forKey: setting.key)
        SettingsChanges.post(setting.key)
    }
}
