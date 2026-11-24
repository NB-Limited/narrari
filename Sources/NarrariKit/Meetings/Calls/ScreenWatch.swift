import Foundation
import Observation

public protocol ScreenWatcher: Sendable {
    // Nil when macOS offers no way to tell.
    func isWatched() -> Bool?
}

// Whether the screen is being shared or recorded, so meeting surfaces can stay off it. Asked once a second, and only
// while a meeting is offered or recording. It never asks which app watches.
@MainActor
@Observable
public final class ScreenWatch {
    public enum State: Sendable, Equatable {
        case watched
        case clear
        case unknown
    }

    public private(set) var state = State.clear

    @ObservationIgnored private let watcher: any ScreenWatcher
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var asking: Task<Void, Never>?

    private static let interval: Duration = .seconds(1)

    public init(watcher: any ScreenWatcher, clock: any Clock<Duration>) {
        self.watcher = watcher
        self.clock = clock
    }

    public func ask(_ isNeeded: Bool) {
        guard isNeeded else {
            asking?.cancel()
            asking = nil
            return
        }
        guard asking == nil else { return }
        // At once, so an offer made during a share is never drawn before the first answer.
        read()
        asking = Task { [weak self, clock] in
            while (try? await clock.sleep(for: Self.interval)) != nil {
                self?.read()
            }
        }
    }

    private func read() {
        state = watcher.isWatched().map { $0 ? .watched : .clear } ?? .unknown
    }
}
