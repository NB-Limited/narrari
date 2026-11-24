import Foundation

public struct LevelMeter: Sendable {
    public struct Bar: Sendable, Equatable {
        public let height: Double
        public let opacity: Double

        public init(height: Double, opacity: Double) {
            self.height = height
            self.opacity = opacity
        }
    }

    public static let folded = [Bar](repeating: Bar(height: 0, opacity: 1), count: profile.count)
    // The beat the level bars and the Halo line both sample the input on.
    public static let sampleInterval = 0.05

    public private(set) var level = 0.0

    static let attack = 0.035
    static let release = 0.18
    static let gamma = 0.7
    static let profile = [0.5, 0.72, 0.9, 1, 0.9, 0.72, 0.5]
    static let quiet = 0.12
    static let breathPeriod = 1.6

    public init() {}

    public mutating func follow(_ input: Float, over seconds: Double) {
        let target = Double(min(max(input, 0), 1))
        let time = target > level ? Self.attack : Self.release
        level += (target - level) * (1 - exp(-seconds / time))
    }

    // The level on the bars' curve: the middle bar's height before its wobble.
    public var loudness: Double {
        pow(level, Self.gamma)
    }

    public func bars(at time: Double, breathing: Bool) -> [Bar] {
        Self.profile.indices.map { index in
            let wobble = 0.86 + 0.14 * sin(time * 9.3 + Double(index) * 1.9)
            let height = min(1, loudness * Self.profile[index] * wobble)
            let breath = breathing
                ? 0.55 + 0.45 * pow(max(0, sin(2 * .pi * time / Self.breathPeriod - Double(index) * 0.45)), 3)
                : 1
            let opacity = height > Self.quiet ? 1 : breath + (1 - breath) * height / Self.quiet
            return Bar(height: height, opacity: opacity)
        }
    }
}

// The bars sample the input on their own beat; a second sample at the same moment leaves the level where it was.
@MainActor
public final class LevelFollower {
    private var meter = LevelMeter()
    private var started: Double?
    private var last: Double?

    public init() {}

    public func bars(following input: Float, at time: Double, breathing: Bool) -> [LevelMeter.Bar] {
        follow(input, at: time)
        let started = started ?? time
        self.started = started
        return meter.bars(at: time - started, breathing: breathing)
    }

    public func loudness(following input: Float, at time: Double) -> Double {
        follow(input, at: time)
        return meter.loudness
    }

    private func follow(_ input: Float, at time: Double) {
        if let last, time > last { meter.follow(input, over: time - last) }
        last = time
    }

    public func restart() {
        meter = LevelMeter()
        started = nil
        last = nil
    }
}
