import Foundation
import Observation

@MainActor
@Observable
public final class GeneralPageModel {
    public private(set) var launchAtLogin = LaunchAtLogin.Status.off
    public private(set) var launchError: String?
    public var followsReduceMotion: Bool {
        get { settings[GeneralSettings.followsReduceMotion] }
        set { settings[GeneralSettings.followsReduceMotion] = newValue }
    }

    @ObservationIgnored private let settings: SettingsMirror
    @ObservationIgnored private let loginStatus: () -> LaunchAtLogin.Status
    @ObservationIgnored private let setLogin: (Bool) throws -> Void

    public init(
        settings: SettingsMirror,
        loginStatus: @escaping () -> LaunchAtLogin.Status = { LaunchAtLogin.status },
        setLogin: @escaping (Bool) throws -> Void = LaunchAtLogin.set
    ) {
        self.settings = settings
        self.loginStatus = loginStatus
        self.setLogin = setLogin
    }

    public var launchDetail: String? {
        launchAtLogin == .needsApproval ? "Waiting for approval in Login Items." : nil
    }

    public func appear() {
        launchAtLogin = loginStatus()
    }

    public func setLaunchAtLogin(_ isOn: Bool) {
        do {
            try setLogin(isOn)
            launchError = nil
        } catch {
            Log.failure("launch-at-login", error: error)
            launchError = isOn
                ? "Narrari could not add itself to the login items. Add it in System Settings, General, Login Items."
                : "Narrari could not remove itself from the login items. Remove it in System Settings, General, Login Items."
        }
        launchAtLogin = loginStatus()
    }
}
