import Synchronization
import Testing

// Every wait in tests/Support gives up after this much real time, so a broken test fails instead of hanging the run.
let waitLimit: Duration = .seconds(10)

// Resumes the continuation once: true from the returned wake, or false with an issue at the deadline. A pass never waits on it.
func wake(
    _ continuation: CheckedContinuation<Bool, Never>,
    for condition: String,
    by deadline: ContinuousClock.Instant = .now + waitLimit,
    at location: SourceLocation
) -> @Sendable () -> Void {
    let pending = Pending(continuation)
    let limit = Task {
        try? await Task.sleep(until: deadline, clock: .continuous)
        guard let continuation = pending.take() else { return }
        Issue.record("Waited \(waitLimit.components.seconds) s for \(condition); it never held.", sourceLocation: location)
        continuation.resume(returning: false)
    }
    return {
        guard let continuation = pending.take() else { return }
        limit.cancel()
        continuation.resume(returning: true)
    }
}

private final class Pending: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = Mutex(continuation)
    }

    func take() -> CheckedContinuation<Bool, Never>? {
        continuation.withLock { $0.take() }
    }
}
