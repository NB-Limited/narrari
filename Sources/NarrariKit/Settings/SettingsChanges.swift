import Foundation

// Settings, word lists and keys announce each change here, so whatever read one at launch can follow it.
public enum SettingsChanges {
    static let notification = Notification.Name("com.nb-limited.narrari.settings-changed")
    private static let outsideNotification = Notification.Name("com.nb-limited.narrari.settings-changed-outside")
    private static let keyField = "key"

    public static func post(_ key: String) {
        NotificationCenter.default.post(name: notification, object: nil, userInfo: [keyField: key])
    }

    public static func updates(of keys: Set<String>) -> AsyncStream<Void> {
        NotificationCenter.default.updates(of: notification) { note in
            (note.userInfo?[keyField] as? String).map(keys.contains) ?? false
        }
    }

    // For the narrari command, which writes from a process of its own. Only the key is sent, never the value.
    public static func postOutside(_ key: String) {
        DistributedNotificationCenter.default().postNotificationName(
            outsideNotification, object: key, userInfo: nil, deliverImmediately: true
        )
    }

    static let settingKeys = Set(SettingsList.all.map(\.key))

    static let fileKeys: Set<String> = [
        DictionaryStore.changeKey, PromptStore.changeKey, ModeStore.changeKey, SummariesPageModel.changeKey, PeoplePageModel.changeKey
    ]

    // Ends with the owner, so a page model needs no teardown.
    @MainActor
    public static func follow<Owner: AnyObject & Sendable>(
        _ keys: Set<String>, by owner: Owner, _ read: @escaping @MainActor (Owner) -> Void
    ) {
        let changes = updates(of: keys)
        Task { [weak owner] in
            for await _ in changes {
                guard let owner else { return }
                read(owner)
            }
        }
    }

    // Run by the app: a setting or file the command wrote is announced like one written in the app, so it applies at once.
    @discardableResult
    public static func followOutsideWrites() -> Task<Void, Never> {
        let known = settingKeys.union(fileKeys)
        let keys = DistributedNotificationCenter.default().objects(of: outsideNotification)
        return Task {
            for await key in keys where known.contains(key) {
                post(key)
            }
        }
    }
}
