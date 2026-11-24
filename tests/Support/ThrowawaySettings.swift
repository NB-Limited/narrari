import Foundation
import NarrariKit

// A UserDefaults suite of its own per test, never the app's domain. An absolute path keeps its file
// in the test's folder, out of ~/Library/Preferences, so it goes with the folder.
final class ThrowawaySettings: @unchecked Sendable {
    let defaults: UserDefaults
    let store: SettingsStore
    private let folder = TemporaryFolder()

    init() {
        defaults = UserDefaults(suiteName: folder.url.appending(path: "settings").path)!
        store = SettingsStore(defaults: defaults)
    }

    // What a page reads the settings through, over the same suite.
    @MainActor
    var mirror: SettingsMirror { SettingsMirror(store) }
}
