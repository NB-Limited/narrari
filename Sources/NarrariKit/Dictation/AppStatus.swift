import Foundation

public enum AppStatus: Equatable {
    case ready
    case recording
    case transcribing
    case cleaning
    case modelLoading(fraction: Double)
    case modelFailed
    case accessibilityMissing
    case microphoneMissing

    @MainActor
    public init(session: DictationSession, permissions: Permissions) {
        switch (session.phase, session.modelState) {
        case (.recording, _): self = .recording
        case (.cleaning, _): self = .cleaning
        case (.transcribing, _), (.pasting, _): self = .transcribing
        case (.idle, _) where !permissions.isAccessibilityAllowed: self = .accessibilityMissing
        case (.idle, _) where permissions.microphone == .denied: self = .microphoneMissing
        case (.idle, .ready): self = .ready
        case (.idle, .preparing(let fraction, _)): self = .modelLoading(fraction: fraction)
        case (.idle, .missing): self = .modelLoading(fraction: 0)
        case (.idle, .failed): self = .modelFailed
        }
    }

    public var title: String {
        switch self {
        case .ready: "Ready"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .cleaning: "Cleaning up"
        case .modelLoading: "Model loading"
        case .modelFailed: "Speech model could not load"
        case .accessibilityMissing: "Accessibility not allowed"
        case .microphoneMissing: "Microphone not allowed"
        }
    }
}
