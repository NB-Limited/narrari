import Synchronization
import Testing

// Holds async work at a point until the test opens it, and tells the test when work has arrived there.
final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var arrivals = 0
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
        var cancelled: Set<Int> = []
        var stopped = 0
        var passed = 0
        var watchers: [(isReady: @Sendable (State) -> Bool, wake: @Sendable () -> Void)] = []

        mutating func takeSatisfiedWatchers() -> [@Sendable () -> Void] {
            let current = self
            let ready = watchers.filter { $0.isReady(current) }.map(\.wake)
            watchers.removeAll { $0.isReady(current) }
            return ready
        }
    }

    private let state = Mutex(State())
    private let honoursCancellation: Bool

    init(honoursCancellation: Bool = true) {
        self.honoursCancellation = honoursCancellation
    }

    // An open gate that only counts who passed.
    static func counter() -> Gate {
        let gate = Gate()
        gate.open()
        return gate
    }

    var arrivals: Int { state.withLock { $0.arrivals } }

    func pass() async throws {
        let id = record { state in
            state.nextID += 1
            state.arrivals += 1
            return state.nextID
        }
        do {
            try await holdOrStop(id)
        } catch {
            record { $0.stopped += 1 }
            throw error
        }
        record { $0.passed += 1 }
    }

    private func holdOrStop(_ id: Int) async throws {
        guard honoursCancellation else { return try await hold(id) }
        try await withTaskCancellationHandler {
            try await hold(id)
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                state.cancelled.insert(id)
                return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    @discardableResult
    private func record<Result>(_ change: (inout State) -> Result) -> Result {
        let (result, watchers) = state.withLock { state in
            (change(&state), state.takeSatisfiedWatchers())
        }
        watchers.forEach { $0() }
        return result
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    func waitForArrivals(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await wait(for: "\(count) arrivals at the gate", at: sourceLocation) { $0.arrivals >= count }
    }

    // Work whose task was cancelled while it was held here.
    func waitForStops(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await wait(for: "\(count) stops at the gate", at: sourceLocation) { $0.stopped >= count }
    }

    // Work that went on after the gate opened.
    func waitForPasses(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await wait(for: "\(count) passes through the gate", at: sourceLocation) { $0.passed >= count }
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

    private func hold(_ id: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            enum Next { case wait, pass, cancel }
            let next = state.withLock { state -> Next in
                if state.cancelled.remove(id) != nil { return .cancel }
                if state.isOpen { return .pass }
                state.waiters[id] = continuation
                return .wait
            }
            switch next {
            case .wait: break
            case .pass: continuation.resume()
            case .cancel: continuation.resume(throwing: CancellationError())
            }
        }
    }
}
