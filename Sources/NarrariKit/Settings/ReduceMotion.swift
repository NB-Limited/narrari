import AppKit
import Observation

// Whether Narrari reduces its motion: the system's Reduce Motion, while the Follow Reduce Motion switch is on.
@MainActor
@Observable
public final class ReduceMotion {
    public static let shared = ReduceMotion(settings: .shared)

    public var isOn: Bool { isSystemOn && follows }

    private var isSystemOn: Bool
    private var follows: Bool

    public init(
        settings: SettingsStore,
        system: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        systemChanges: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        isSystemOn = system()
        follows = settings.value(GeneralSettings.followsReduceMotion)
        let followChanges = SettingsChanges.updates(of: [GeneralSettings.followsReduceMotion.key])
        let systemUpdates = systemChanges.updates(of: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        Task { [weak self] in
            for await _ in followChanges {
                guard let self else { return }
                follows = settings.value(GeneralSettings.followsReduceMotion)
            }
        }
        Task { [weak self] in
            for await _ in systemUpdates {
                guard let self else { return }
                isSystemOn = system()
            }
        }
    }
}
