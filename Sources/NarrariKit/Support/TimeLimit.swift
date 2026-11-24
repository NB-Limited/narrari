import Foundation

public struct TimeLimitExceeded: ProblemError, Equatable {
    public var problem: Problem { Problem("time-limit", "This took too long. Try again.", canRetry: true) }
}

func withTimeLimit<Value: Sendable>(
    _ limit: Duration,
    clock: any Clock<Duration>,
    _ work: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await firstToFinish(work) {
        try await clock.sleep(for: limit)
        throw TimeLimitExceeded()
    }
}

extension Clock where Duration == Swift.Duration {
    // The time left of a limit started now, read again at each call.
    func countdown(from limit: Duration) -> @Sendable () -> Duration {
        let end = now.advanced(by: limit)
        return { now.duration(to: end) }
    }
}
