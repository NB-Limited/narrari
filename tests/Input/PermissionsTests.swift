import AppKit
import NarrariKit
import Synchronization
import Testing

private final class Grant: Sendable {
    private let state = Mutex(true)
    var isOn: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

@MainActor
struct PermissionsTests {
    private let clock = TestClock()
    private let grant = Grant()
    private let settings = ThrowawaySettings()

    private func permissions() -> Permissions {
        let grant = grant
        return Permissions(
            settings: settings.store,
            access: InputAccess(isAccessibilityGranted: { grant.isOn }),
            microphoneStatus: { .authorized },
            clock: clock
        )
    }

    @Test func grant_taken_back_is_noticed_when_narrari_becomes_active() async {
        let permissions = permissions()
        permissions.start()
        #expect(clock.pendingSleepers == 0)

        grant.isOn = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        await until { !permissions.isAccessibilityAllowed }
    }

    @Test func missing_grant_is_polled_until_it_arrives() async {
        grant.isOn = false
        let permissions = permissions()
        permissions.start()

        grant.isOn = true
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        await until { permissions.isAccessibilityAllowed }

        #expect(clock.pendingSleepers == 0)
    }

    @Test func the_calendar_is_asked_for_only_on_request_and_never_needed_for_all_set() async {
        let calendarGrant = Grant()
        calendarGrant.isOn = false
        let permissions = Permissions(
            settings: settings.store, access: .fixed(), microphoneStatus: { .authorized },
            calendarStatus: { calendarGrant.isOn ? .fullAccess : .notDetermined }, askForCalendar: { calendarGrant.isOn = true }
        )
        #expect(permissions.isComplete && permissions.calendar == .notAsked)

        permissions.requestCalendar()

        await until { permissions.calendar == .allowed }
    }

    @Test func the_system_audio_row_says_what_recordings_heard_and_keeps_it_across_launches() {
        #expect(permissions().systemAudio.status == "Asked at your first recording")

        permissions().record(.silent)

        #expect(permissions().systemAudio.status.hasPrefix("Other people's sound was not recorded."))
        permissions().record(.allowed)
        #expect(permissions().systemAudio.status == "Allowed")
    }
}
