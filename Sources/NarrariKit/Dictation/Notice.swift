import Foundation

public enum Notice: Sendable, Equatable {
    case copiedAccessibilityOff
    case copiedKeystrokeFailed
    case nothingToPaste
    case nothingHeard
    case microphone(RecorderError)
    case microphoneDisconnected
    case microphoneSwitched(String?)
    case speech(TranscriberError)
    case discarded
    case cleanupOn
    case cleanupOff
    case mode(String)
    case cleanupSkipped(CleanupResult.Reason)
    case speechFallback(SpeechFallbackReason)

    public var message: String {
        switch self {
        case .copiedAccessibilityOff: "Accessibility is off. Press ⌘V instead."
        case .copiedKeystrokeFailed: "Could not paste. Press ⌘V instead."
        case .nothingToPaste: "No dictation to paste"
        case .nothingHeard: "Nothing heard"
        case .microphone(let error): error.problem.message
        case .microphoneDisconnected: "Microphone disconnected. Transcribing the rest."
        case .microphoneSwitched(let name): "Switched to \(name ?? "another microphone")"
        case .speech(let error): error.problem.message
        case .discarded: "Discarded. The audio is kept."
        case .cleanupOn: "Clean-up on for this dictation"
        case .cleanupOff: "Clean-up off for this dictation"
        case .mode(let name): name
        case .cleanupSkipped(let reason): Self.cleanupReason(reason) + " Pasted as spoken."
        case .speechFallback(let reason): Self.message(for: reason)
        }
    }

    // An error stays until the next dictation; any other notice fades.
    public var isError: Bool {
        switch self {
        case .microphone(let error): error != .microphoneAccessRequested
        case .microphoneDisconnected, .speech: true
        case .copiedAccessibilityOff, .copiedKeystrokeFailed, .nothingToPaste, .nothingHeard,
             .microphoneSwitched, .discarded, .cleanupOn, .cleanupOff, .mode, .cleanupSkipped, .speechFallback: false
        }
    }

    // Nil when the text was pasted.
    public init?(_ outcome: PasteOutcome) {
        switch outcome {
        case .pasted: return nil
        case .copiedAccessibilityOff: self = .copiedAccessibilityOff
        case .copiedKeystrokeFailed: self = .copiedKeystrokeFailed
        }
    }

    // Why clean-up did not run; the caller adds what became of the text.
    public static func cleanupReason(_ reason: CleanupResult.Reason) -> String {
        switch reason {
        case .modelLoading: "Clean-up model still loading."
        case .modelUnavailable: "Clean-up model unavailable."
        case .timedOut: "Clean-up took too long."
        case .engineFailed: "Clean-up failed."
        case .emptyReply, .replyTooLong, .unlikeDictation: "Clean-up reply unusable."
        case .notSetUp: "Clean-up service not set up."
        case .nothingToClean, .switchedOff, .hotkey, .skippedLanguage: "Clean-up is off."
        }
    }

    private static func message(for reason: SpeechFallbackReason) -> String {
        switch reason {
        case .serviceFailed: "Outside service failed. Transcribed on this Mac."
        case .timedOut: "Outside service too slow. Transcribed on this Mac."
        case .overLimit: "Too large for the outside service. Used this Mac."
        }
    }
}
