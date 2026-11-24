import Foundation

// Service keys sit in the Keychain, not in settings, so no key is ever listed, read or written here.
enum SettingsCommand {
    static func list(_ settings: SettingsStore) -> String {
        let rows = SettingsList.all.map { setting in
            let value = setting.text(in: settings)
            return (mark: value == setting.defaultText ? " " : "*", key: setting.key, value: shown(value), fallback: shown(setting.defaultText))
        }
        let keyWidth = rows.map(\.key.count).max() ?? 0
        let valueWidth = max(rows.map(\.value.count).max() ?? 0, 5)
        let head = "  \("KEY".padded(to: keyWidth))  \("VALUE".padded(to: valueWidth))  DEFAULT"
        let lines = rows.map { "\($0.mark) \($0.key.padded(to: keyWidth))  \($0.value.padded(to: valueWidth))  \($0.fallback)" }
        return ([head] + lines).joined(separator: "\n") + "\n\n* changed from its default\n"
    }

    static func get(_ key: String, in settings: SettingsStore) -> Command.Reply {
        guard let setting = SettingsList.setting(key) else { return unknown(key) }
        return .ok(setting.text(in: settings) + "\n")
    }

    static func set(_ key: String, to text: String, in context: Command.Context) -> Command.Reply {
        guard let setting = SettingsList.setting(key) else { return unknown(key) }
        guard setting.set(text, in: context.settings) else {
            return .failed("\(shown(text)) is not a value for \(key). Use \(setting.allowed).\n")
        }
        context.announce(key)
        return .ok("\(key) is now \(shown(setting.text(in: context.settings))).\n")
    }

    static func reset(_ key: String, in context: Command.Context) -> Command.Reply {
        guard let setting = SettingsList.setting(key) else { return unknown(key) }
        setting.reset(in: context.settings)
        context.announce(key)
        return .ok("\(key) is back to its default, \(shown(setting.defaultText)).\n")
    }

    private static func unknown(_ key: String) -> Command.Reply {
        .failed("\(key) is not a setting. The settings are:\n" + SettingsList.all.map { "  \($0.key)\n" }.joined())
    }

    // An empty value shows as "", so it can be told from a missing column.
    private static func shown(_ text: String) -> String {
        text.isEmpty ? "\"\"" : text
    }
}

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
