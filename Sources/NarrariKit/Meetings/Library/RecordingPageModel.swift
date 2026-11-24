import AppKit
import Observation

// The Recording page in settings: how a call's recording starts, stops and shows, and the apps to leave alone.
@MainActor
@Observable
public final class RecordingPageModel {
    public var startsByItself: Bool {
        get { settings[MeetingsSettings.startsByItself] }
        set { settings[MeetingsSettings.startsByItself] = newValue }
    }
    public var stopsWithCall: Bool {
        get { settings[MeetingsSettings.stopsWithCall] }
        set { settings[MeetingsSettings.stopsWithCall] = newValue }
    }
    public var showsLiveText: Bool {
        get { settings[MeetingsSettings.showsLiveText] }
        set { settings[MeetingsSettings.showsLiveText] = newValue }
    }
    public var bar: MeetingBar {
        get { settings[MeetingsSettings.bar] }
        set { settings[MeetingsSettings.bar] = newValue }
    }
    public var readsCallWindowNames: Bool {
        get { settings[MeetingsSettings.readsCallWindowNames] }
        set { settings[MeetingsSettings.readsCallWindowNames] = newValue }
    }
    public var ignoredApps: [String] { settings[MeetingsSettings.ignoredApps] }
    private var installedApps: [AppDirectory.Listing] = []

    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored public let apps: AppDirectory

    public init(settings: SettingsMirror, apps: AppDirectory) {
        self.settings = settings
        self.apps = apps
    }

    public var appChoices: [AppDirectory.Listing] {
        let ignored = Set(ignoredApps)
        return installedApps.filter { !ignored.contains($0.bundleIdentifier) }
    }

    public func appear() async {
        installedApps = await apps.installedAndRunning()
    }

    public func ignore(_ bundleIdentifier: String) {
        guard !ignoredApps.contains(bundleIdentifier) else { return }
        settings[MeetingsSettings.ignoredApps] = ignoredApps + [bundleIdentifier]
    }

    public func stopIgnoring(_ bundleIdentifier: String) {
        settings[MeetingsSettings.ignoredApps] = ignoredApps.filter { $0 != bundleIdentifier }
    }
}
