import Observation

// A flag that turns on after a delay or for a while, such as a button's label on hover or its "Copied".
// Every change cancels the one pending, so a quick leave never shows the label and a second copy restarts the hold.
@MainActor
@Observable
public final class TimedFlag {
    public private(set) var isOn = false

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var pending: Task<Void, Never>?

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    public func turnOn(after delay: Duration) {
        guard !isOn, pending == nil else { return }
        schedule(after: delay, to: true)
    }

    public func turnOn(for duration: Duration) {
        pending?.cancel()
        isOn = true
        schedule(after: duration, to: false)
    }

    public func turnOff() {
        pending?.cancel()
        pending = nil
        isOn = false
    }

    private func schedule(after delay: Duration, to value: Bool) {
        pending = Task { [weak self, clock] in
            guard (try? await clock.sleep(for: delay)) != nil, !Task.isCancelled else { return }
            self?.isOn = value
            self?.pending = nil
        }
    }
}
