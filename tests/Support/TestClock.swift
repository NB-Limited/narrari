import Foundation
import Synchronization
import Testing

// A clock that moves only when a test advances it. Sleepers whose deadline passes wake in deadline order.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var cancelled: Set<Int> = []
        var watchers: [(isReady: @Sendable (State) -> Bool, wake: @Sendable () -> Void)] = []

        mutating func takeSatisfiedWatchers() -> [@Sendable () -> Void] {
            let current = self
            let ready = watchers.filter { $0.isReady(current) }.map(\.wake)
            watchers.removeAll { $0.isReady(current) }
            return ready
        }
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var pendingSleepers: Int { state.withLock { $0.sleepers.count } }

    var seconds: TimeInterval {
        let parts = now.offset.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Next { case wait, wake, cancel }
                let (next, watchers) = state.withLock { state -> (Next, [@Sendable () -> Void]) in
                    if state.cancelled.remove(id) != nil { return (.cancel, []) }
                    if deadline <= state.now { return (.wake, []) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return (.wait, state.takeSatisfiedWatchers())
                }
                watchers.forEach { $0() }
                switch next {
                case .wait: break
                case .wake: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
                state.cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            due.keys.forEach { state.sleepers.removeValue(forKey: $0) }
            return due.values.sorted { $0.deadline < $1.deadline }
        }
        due.forEach { $0.continuation.resume() }
    }

    // Returns once at least this many sleepers are waiting, so a test advances only after the work it means to wake is asleep.
    func waitForSleepers(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await wait(for: "\(count) sleepers on the test clock", at: sourceLocation) { $0.sleepers.count >= count }
    }

    // Returns once a sleeper with this deadline is waiting, which no other timer of the code under test can stand in for.
    func waitForSleeper(until deadline: Instant, sourceLocation: SourceLocation = #_sourceLocation) async {
        await wait(for: "a sleeper until \(deadline.offset) on the test clock", at: sourceLocation) {
            $0.sleepers.values.contains { $0.deadline == deadline }
        }
    }

    private func wait(for condition: String, at location: SourceLocation, until isReady: @escaping @Sendable (State) -> Bool) async {
        _ = await withCheckedContinuation { continuation in
            let woken = wake(continuation, for: condition, at: location)
            let isReadyNow = state.withLock { state -> Bool in
                guard !isReady(state) else { return true }
                state.watchers.append((isReady, woken))
                return false
            }
            if isReadyNow { woken() }
        }
    }
}
