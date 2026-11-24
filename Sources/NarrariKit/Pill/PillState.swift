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

    public static let transcribing = PillLabel(symbol: "waveform", text: WorkState.Activity.transcribing.label)
    public static let cleaning = PillLabel(symbol: "text.alignleft", text: WorkState.Activity.cleaningUp.label)
    public static let waitingForModel = PillLabel(symbol: "hourglass", text: WaitReason.speechModel.label)

    // The speech model on its way while a dictation records: "Downloading" or "Getting ready", without a figure, so the pill keeps its width.
    static func model(_ state: ModelState) -> PillLabel? {
        state.work.activity.map { PillLabel(symbol: "hourglass", text: $0.label) }
    }

    public init(_ notice: Notice) {
        let symbol = switch notice {
        case .copiedAccessibilityOff: "accessibility"
        case .nothingHeard: "waveform.slash"
        case .copiedKeystrokeFailed, .nothingToPaste: "exclamationmark.circle"
        case .microphone(.microphoneAccessRequested), .microphoneSwitched: "mic.fill"
        case .microphone, .microphoneDisconnected: "mic.slash.fill"
        case .speech: "exclamationmark.triangle.fill"
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
        let refusals: [RecorderError] = [.microphoneDenied, .microphoneAccessRequested, .noInput, .startFailed]
        switch notice {
        case .failed(let problem):
            if let refusal = refusals.first(where: { $0.problem == problem }) {
                self.init(.microphone(refusal))
            } else {
                self.init(symbol: "exclamationmark.triangle.fill", text: notice.message, isError: true)
            }
        case .liveText: self.init(symbol: "exclamationmark.circle", text: notice.message)
        }
    }

    public init(_ trouble: RecordingTrouble) {
        let symbol = trouble == RecordingTrouble(track: .mic, kind: .stopped) ? "mic.slash.fill" : "exclamationmark.triangle.fill"
        self.init(symbol: symbol, text: trouble.message, isError: true)
    }
}
