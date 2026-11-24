import Foundation

public struct PillLabel: Sendable, Equatable {
    public let symbol: String
    public let text: String
    public let isError: Bool

    public init(symbol: String, text: String, isError: Bool = false) {
        self.symbol = symbol
        self.text = text
        self.isError = isError
    }

    public static let transcribing = PillLabel(symbol: "waveform", text: "Transcribing")
    public static let cleaning = PillLabel(symbol: "text.alignleft", text: "Cleaning up")
    public static let modelLoading = PillLabel(symbol: "hourglass", text: "Model loading")

    public init(_ notice: Notice) {
        let symbol = switch notice {
        case .copiedAccessibilityOff: "accessibility"
        case .nothingHeard: "waveform.slash"
        case .copiedKeystrokeFailed, .nothingToPaste: "exclamationmark.circle"
        case .microphoneAccessRequested, .microphoneSwitched: "mic.fill"
        case .microphoneDenied, .microphoneUnavailable, .microphoneDisconnected: "mic.slash.fill"
        case .modelUnavailable, .modelFailed, .transcriptionFailed: "exclamationmark.triangle.fill"
        case .discarded: "trash"
        case .cleanupOn: "text.badge.checkmark"
        case .cleanupOff: "text.badge.xmark"
        case .mode: "rectangle.stack"
        case .cleanupSkipped: "exclamationmark.circle"
        case .speechFallback: "network.slash"
        }
        self.init(symbol: symbol, text: notice.message, isError: notice.isError)
    }
}

public enum PillCapsule: Sendable, Equatable {
    case recording(slot: PillLabel?)
    case working(PillLabel)
    case notice(PillLabel)
    case done

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var announcement: String {
        switch self {
        case .recording(nil): "Recording"
        case .recording(let slot?): slot.text
        case .working(let label), .notice(let label): label.text
        case .done: "Pasted"
        }
    }
}

public struct PillState: Sendable, Equatable {
    public var capsule: PillCapsule
    public var caption: String?
    // Shown on the plate in every look, also with live text off.
    public var silentMicrophone: String?

    public init(capsule: PillCapsule, caption: String? = nil, silentMicrophone: String? = nil) {
        self.capsule = capsule
        self.caption = caption
        self.silentMicrophone = silentMicrophone
    }
}

extension PillLabel {
    public init(_ notice: MeetingNotice) {
        switch notice {
        case .refused(let refusal): self.init(refusal)
        case .lowDisk, .stoppedForLowDisk, .failed: self.init(symbol: "exclamationmark.triangle.fill", text: notice.message, isError: true)
        case .liveText: self.init(symbol: "exclamationmark.circle", text: notice.message)
        }
    }

    public init(_ trouble: RecordingTrouble) {
        let symbol = trouble == RecordingTrouble(track: .mic, kind: .stopped) ? "mic.slash.fill" : "exclamationmark.triangle.fill"
        self.init(symbol: symbol, text: trouble.message, isError: true)
    }
}
