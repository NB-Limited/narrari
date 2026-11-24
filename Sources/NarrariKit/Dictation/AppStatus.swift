import Foundation

public enum AppStatus: Equatable {
    case ready
    case recording
    // A dictation after its recording: transcribing, cleaning up, or waiting for the speech model.
    case dictation(WorkState)
    // The speech model on its way while no dictation runs: downloading or getting ready.
    case model(WorkState)
    case modelFailed
    case accessibilityMissing
    case microphoneMissing

    @MainActor
    public init(session: DictationSession, permissions: Permissions) {
        switch (session.phase, session.modelState) {
        case (.recording, _): self = .recording
        case (.transcribing, _), (.cleaning, _), (.pasting, _): self = .dictation(session.work)
        case (.idle, _) where !permissions.isAccessibilityAllowed: self = .accessibilityMissing
        case (.idle, _) where permissions.microphone == .denied: self = .microphoneMissing
        case (.idle, .ready): self = .ready
        case (.idle, .preparing): self = .model(session.modelState.work)
        case (.idle, .missing): self = .model(.working(.downloading, progress: 0))
        case (.idle, .failed): self = .modelFailed
        }
    }

    public var title: String {
        switch self {
        case .ready: "Ready"
        case .recording: "Recording"
        case .dictation(let work), .model(let work): work.label
        case .modelFailed: "Speech model could not load"
        case .accessibilityMissing: "Accessibility not allowed"
        case .microphoneMissing: "Microphone not allowed"
        }
    }
}
