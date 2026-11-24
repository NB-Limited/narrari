import AppKit
import NarrariKit
import Testing

@MainActor
struct ReduceMotionTests {
    private let settings = ThrowawaySettings()
    private let systemChanges = NotificationCenter()
    private let system = SystemSetting()

    private func motion() -> ReduceMotion {
        ReduceMotion(settings: settings.store, system: { [system] in system.isOn }, systemChanges: systemChanges)
    }

    @Test func turning_the_switch_off_keeps_full_motion_while_the_system_reduces_it() async {
        system.isOn = true
        let motion = motion()
        #expect(motion.isOn)

        settings.store.set(false, for: GeneralSettings.followsReduceMotion)
        await until { !motion.isOn }

        settings.store.set(true, for: GeneralSettings.followsReduceMotion)
        await until { motion.isOn }
    }

    @Test func a_change_in_system_settings_takes_effect_without_a_restart() async {
        let motion = motion()
        #expect(!motion.isOn)

        system.isOn = true
        systemChanges.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        await until { motion.isOn }
    }
}

@MainActor
private final class SystemSetting {
    var isOn = false
}
