import Observation
import Testing

// Suspends until an observable condition holds, woken by each change it reads; never by time, short of the wait limit.
@MainActor
func until(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now + waitLimit
    while !condition() {
        let woke = await withCheckedContinuation { continuation in
            let woken = wake(continuation, for: "the condition", by: deadline, at: sourceLocation)
            withObservationTracking {
                _ = condition()
            } onChange: {
                woken()
            }
        }
        guard woke else { return }
    }
}
