import AppKit
import AVFoundation
import EventKit
import Observation

@MainActor
@Observable
public final class Permissions {
    public enum Microphone: CaseIterable, Sendable, Equatable {
        case allowed
        case denied
        case notAsked

        // Logged at launch and on each change; narrari doctor reads it back, because a terminal sees only its own grants.
        public var logName: StaticString {
            switch self {
            case .allowed: "permission-microphone-allowed"
            case .denied: "permission-microphone-denied"
            case .notAsked: "permission-microphone-not-asked"
            }
        }
    }

    // Optional: it only names meetings and the people in them.
    public enum CalendarAccess: Sendable, Equatable {
        case allowed
        case denied
        case notAsked
    }

    // macOS asks at the first recording and never tells an app the answer, so a recording's sound is the only sign.
    public enum SystemAudio: String, CaseIterable, Sendable {
        case notRecorded
        case allowed
        case silent

        public var status: String {
            switch self {
            case .notRecorded: "Asked at your first recording"
            case .allowed: "Allowed"
            case .silent:
                "Other people's sound was not recorded. Allow it in System Settings, Privacy and Security, Screen and System Audio Recording."
            }
        }
    }

    public nonisolated static func accessibilityLogName(isAllowed: Bool) -> StaticString {
        isAllowed ? "permission-accessibility-allowed" : "permission-accessibility-off"
    }

    public private(set) var microphone = Microphone.notAsked
    public private(set) var isAccessibilityAllowed = false
    public private(set) var calendar = CalendarAccess.notAsked
    public private(set) var systemAudio: SystemAudio

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let access: InputAccess
    @ObservationIgnored private let microphoneStatus: @Sendable () -> AVAuthorizationStatus
    @ObservationIgnored private let calendarStatus: @Sendable () -> EKAuthorizationStatus
    @ObservationIgnored private let askForCalendar: @Sendable () async -> Void
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var isReported = false

    private static let pollInterval: Duration = .seconds(1)
    private static let microphonePane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!
    private static let calendarPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )!
    // System audio recording sits on the Screen & System Audio Recording pane.
    private static let systemAudioPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    public var isComplete: Bool { microphone == .allowed && isAccessibilityAllowed }

    public init(
        settings: SettingsStore,
        access: InputAccess = .system,
        microphoneStatus: @escaping @Sendable () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        calendarStatus: @escaping @Sendable () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) },
        askForCalendar: @escaping @Sendable () async -> Void = { _ = try? await EKEventStore().requestFullAccessToEvents() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.settings = settings
        self.access = access
        self.microphoneStatus = microphoneStatus
        self.calendarStatus = calendarStatus
        self.askForCalendar = askForCalendar
        self.clock = clock
        systemAudio = settings.value(MeetingsSettings.systemAudio)
        refresh()
    }

    isolated deinit {
        polling?.cancel()
        activation?.cancel()
    }

    // The one owner of this state. It is read again whenever Narrari becomes active, so a grant taken back is noticed.
    public func start() {
        watch()
        guard activation == nil else { return }
        let activations = NotificationCenter.default.updates(of: NSApplication.didBecomeActiveNotification)
        activation = Task { [weak self] in
            for await _ in activations {
                guard let self else { return }
                refresh()
                watch()
            }
        }
    }

    public func refresh() {
        let before = (microphone, isAccessibilityAllowed)
        microphone = switch microphoneStatus() {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        isAccessibilityAllowed = access.isAccessibilityGranted()
        calendar = switch calendarStatus() {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        guard !isReported || before != (microphone, isAccessibilityAllowed) else { return }
        isReported = true
        Log.event(microphone.logName)
        Log.event(Self.accessibilityLogName(isAllowed: isAccessibilityAllowed))
    }

    // Grants arrive from System Settings with no notice, so the state is read again each second until both are in.
    public func watch() {
        guard polling == nil, !isComplete else { return }
        polling = Task { [weak self, clock] in
            while (try? await clock.sleep(for: Self.pollInterval)) != nil {
                guard let self else { return }
                refresh()
                if isComplete { break }
            }
            self?.polling = nil
        }
    }

    // Asks the first time; a recorder calls it before it opens the microphone.
    public func requireMicrophone() throws {
        refresh()
        switch microphone {
        case .allowed:
            return
        case .notAsked:
            requestMicrophone()
            throw RecorderError.microphoneAccessRequested
        case .denied:
            throw RecorderError.microphoneDenied
        }
    }

    public func requestMicrophone() {
        guard microphone == .notAsked else {
            NSWorkspace.shared.open(Self.microphonePane)
            return
        }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        }
    }

    public static func openSystemAudioSettings() {
        NSWorkspace.shared.open(systemAudioPane)
    }

    // Only ever from the Permissions page: Narrari never asks for the calendar by itself.
    public func requestCalendar() {
        guard calendar == .notAsked else {
            NSWorkspace.shared.open(Self.calendarPane)
            return
        }
        Task { [askForCalendar] in
            await askForCalendar()
            refresh()
        }
    }

    public func record(_ systemAudio: SystemAudio) {
        settings.set(systemAudio, for: MeetingsSettings.systemAudio)
        self.systemAudio = systemAudio
    }

    public func requestAccessibility() {
        InputAccess.requestAccessibility()
        watch()
    }
}
