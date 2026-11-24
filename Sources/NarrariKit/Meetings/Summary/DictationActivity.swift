public protocol DictationActivity: Sendable {
    // The state now, then every change; true while a dictation is in progress.
    func updates() -> AsyncStream<Bool>
}
