import Synchronization

// Returns as soon as one piece of work finishes or the caller is cancelled; the rest are cancelled and never awaited.
func firstToFinish<Value: Sendable>(_ works: (@Sendable () async throws -> Value)...) async throws -> Value {
    let first = FirstResult<Value>()
    let tasks = works.map { work in
        Task {
            do {
                first.resolve(.success(try await work()))
            } catch {
                first.resolve(.failure(error))
            }
        }
    }
    defer { tasks.forEach { $0.cancel() } }
    return try await withTaskCancellationHandler {
        try await first.value()
    } onCancel: {
        first.resolve(.failure(CancellationError()))
    }
}

private final class FirstResult<Value: Sendable>: Sendable {
    private enum State {
        case waiting(CheckedContinuation<Value, any Error>?)
        case done(Result<Value, any Error>)
    }

    private let state = Mutex(State.waiting(nil))

    func resolve(_ result: Result<Value, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard case .waiting(let waiter) = state else { return nil }
            state = .done(result)
            return waiter
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let done = state.withLock { state -> Result<Value, any Error>? in
                switch state {
                case .waiting:
                    state = .waiting(continuation)
                    return nil
                case .done(let result):
                    return result
                }
            }
            if let done { continuation.resume(with: done) }
        }
    }
}
