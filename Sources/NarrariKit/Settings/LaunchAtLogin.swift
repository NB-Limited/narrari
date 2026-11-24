import ServiceManagement

public enum LaunchAtLogin {
    public enum Status: Sendable, Equatable {
        case on
        case off
        case needsApproval
    }

    public static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    public static func set(_ isOn: Bool) throws {
        if isOn {
            try SMAppService.mainApp.register()
            Log.event("launch-at-login-on")
        } else {
            try SMAppService.mainApp.unregister()
            Log.event("launch-at-login-off")
        }
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
