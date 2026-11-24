import Foundation

public struct TimeLimitExceeded: Error, Equatable {}

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
