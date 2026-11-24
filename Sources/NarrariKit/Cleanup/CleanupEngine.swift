import Foundation

public enum CleanupEngineError: ProblemError, Equatable {
    case modelUnavailable
    case generationFailed(status: Int? = nil)
    case replyTooLong

    public var problem: Problem {
        switch self {
        case .modelUnavailable: Problem("cleanup.model-unavailable", "The clean-up model did not load. Try again in Settings, Clean-up.", canRetry: true)
        case .generationFailed: Problem("cleanup.failed", "Clean-up failed. Try again, or choose another model.", canRetry: true)
        case .replyTooLong: Problem("cleanup.too-long", "The clean-up reply ran too long. Try again.", canRetry: true)
        }
    }

    public var status: Int? {
        if case .generationFailed(let status) = self { return status }
        return nil
    }
}

// How long a reply may grow from the transcript. The in-app model counts tokens and stops there; a service's reply is
// counted in characters, at the 4 characters a token that English measured.
public struct ReplyGrowth: Sendable, Equatable {
    public let factor: Int
    public let extra: Int
    // Measured 22-Nov-26: at temperature 0 a summary can repeat one line until its budget ends; clean-up never needs this.
    var repeatPenalty: Float?
    static let repeatWindow = 256

    static func long(tokens: Int) -> ReplyGrowth {
        ReplyGrowth(factor: 0, extra: tokens, repeatPenalty: 1.5)
    }

    public func tokenLimit(for tokens: Int) -> Int { tokens * factor + extra }
    public func characterLimit(for characters: Int) -> Int { characters * factor + extra * 4 }
}

public protocol CleanupEngine: Sendable {
    var name: String { get }
    var runsInApp: Bool { get }
    var state: ModelState { get async }

    func load() async throws
    func unload() async
    func rewrite(_ transcript: String, instruction: String, growth: ReplyGrowth) async throws -> String
}

// An in-app engine that decodes a dictation's pieces together. A nil reply is a piece it could not finish there.
public protocol BatchCleanupEngine: CleanupEngine {
    func rewrite(together transcripts: [String], instruction: String, growth: ReplyGrowth) async throws -> [String?]
}

public enum CleanupEngineKind: String, CaseIterable, Sendable {
    case local
    case chat
}

public enum CleanupEngines {
    // A chat service that is chosen but unusable means no engine: clean-up is skipped, the local model is not loaded instead.
    public static func selected(
        settings: SettingsStore,
        keychain: any KeyStoring,
        store: ModelStore,
        onStateChange: @escaping @Sendable (ModelState) -> Void = { _ in }
    ) -> (any CleanupEngine)? {
        switch settings.value(CleanupSettings.engine) {
        case .chat:
            ChatClient(settings: settings, keychain: keychain)
        case .local:
            LocalModelEngine(
                model: ModelReference(settings.value(CleanupSettings.localModel)), store: store, onStateChange: onStateChange
            )
        }
    }
}
