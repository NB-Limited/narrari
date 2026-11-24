import Foundation
import Observation

// Models report from their own actors; the stream keeps the reports in order on their way to the main actor.
@MainActor
@Observable
public final class ModelStatus {
    public private(set) var state = ModelState.missing

    private let sink: AsyncStream<ModelState>.Continuation

    public init() {
        let (states, sink) = AsyncStream.makeStream(of: ModelState.self)
        self.sink = sink
        Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.state = state
            }
        }
    }

    public nonisolated var report: @Sendable (ModelState) -> Void {
        { [sink] state in sink.yield(state) }
    }
}
