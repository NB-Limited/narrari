import Observation

// Whether a dictation is in progress, for work that gives way to it. The app makes this before the dictation session
// exists and hands the session over once it does; until then nothing is in progress.
@MainActor
public final class DictationWatch: DictationActivity {
    public weak var session: DictationSession?

    public init() {}

    public nonisolated func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            Task { @MainActor in self.follow(continuation) }
        }
    }

    private func follow(_ continuation: AsyncStream<Bool>.Continuation) {
        guard let session else {
            continuation.yield(false)
            continuation.finish()
            return
        }
        if case .terminated = continuation.yield(session.phase != .idle) { return }
        withObservationTracking {
            _ = session.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(continuation) }
        }
    }
}
