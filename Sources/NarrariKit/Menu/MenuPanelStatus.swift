import Foundation

// What the menu bar panel says at the top, and the one action that clears a problem.
// A dictation under way or a problem to fix comes first; then a meeting, in place of Ready or the model loading.
public enum MenuPanelStatus: Equatable, Sendable {
    case ready(hotkey: String)
    case recording(elapsed: String, hotkey: String)
    case busy(title: String)
    case loading(fraction: Double)
    case problem(title: String, fix: MenuPanelAction)
    // The meeting's time is shown while it records or is paused.
    case meeting(title: String, elapsed: String?)

    public init(_ status: AppStatus, meeting: MeetingSession.State, hotkey: String, elapsed: TimeInterval, meetingElapsed: TimeInterval) {
        switch (status, meeting) {
        case (.ready, .recording), (.modelLoading, .recording):
            self = .meeting(title: "Recording meeting", elapsed: MeetingSurfaces.elapsedText(seconds: meetingElapsed))
        case (.ready, .paused), (.modelLoading, .paused):
            self = .meeting(title: "Meeting paused", elapsed: MeetingSurfaces.elapsedText(seconds: meetingElapsed))
        case (.ready, .processing), (.modelLoading, .processing):
            self = .meeting(title: "Writing up the meeting", elapsed: nil)
        default:
            self.init(status, hotkey: hotkey, elapsed: elapsed)
        }
    }

    private init(_ status: AppStatus, hotkey: String, elapsed: TimeInterval) {
        switch status {
        case .ready: self = .ready(hotkey: hotkey)
        case .recording: self = .recording(elapsed: EntryFormat.position(elapsed), hotkey: hotkey)
        case .transcribing, .cleaning: self = .busy(title: status.title)
        case .modelLoading(let fraction): self = .loading(fraction: fraction)
        case .modelFailed: self = .problem(title: status.title, fix: .openSpeechSettings)
        case .accessibilityMissing: self = .problem(title: status.title, fix: .allowAccessibility)
        case .microphoneMissing: self = .problem(title: status.title, fix: .allowMicrophone)
        }
    }

    public var title: String {
        switch self {
        case .ready: "Ready"
        case .recording: "Recording"
        case .busy(let title), .problem(let title, _), .meeting(let title, _): title
        case .loading: "Speech model loading"
        }
    }

    // A fresh download reports nothing for a moment; no figure reads better than "0%".
    public var percent: String? {
        guard case .loading(let fraction) = self, fraction > 0 else { return nil }
        return MetricText.percent(min(fraction, 1))
    }

    public var fixTitle: String? {
        guard case .problem(_, let fix) = self else { return nil }
        return switch fix {
        case .allowAccessibility: "Open Accessibility Settings"
        case .allowMicrophone: "Open Microphone Settings"
        default: "Open Speech Settings"
        }
    }
}

public struct DictationRow: Equatable, Sendable {
    public let title: String
    public let isEnabled: Bool
    // Said to VoiceOver when the row is disabled.
    public let reason: String?

    @MainActor
    init(session: DictationSession, status: AppStatus) {
        switch status {
        case _ where session.phase == .recording: self.init(title: "Stop dictation")
        case _ where session.isWaitingForModel: self.init(title: "Stop waiting")
        case .transcribing, .cleaning, .accessibilityMissing, .microphoneMissing:
            self.init(title: "Start dictation", reason: status.title)
        default: self.init(title: "Start dictation")
        }
    }

    private init(title: String, reason: String? = nil) {
        self.title = title
        isEnabled = reason == nil
        self.reason = reason
    }
}
