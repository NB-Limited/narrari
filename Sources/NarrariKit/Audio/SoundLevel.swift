import Foundation

// How loud a buffer is, for the level meter and for telling sound from a dead input.
enum SoundLevel {
    private static let silenceDecibels: Float = -50
    // Kept far under a quiet room's floor (taken as -90 dBFS, -96 per buffer here): a false "No sound" is worse than none.
    private static let soundFloorDecibels: Float = -110

    static func decibels(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        let power = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        return 10 * log10(max(power, 1e-20))
    }

    static func meter(_ decibels: Float) -> Float {
        min(max(1 - decibels / silenceDecibels, 0), 1)
    }

    static func isSound(_ decibels: Float) -> Bool {
        decibels >= soundFloorDecibels
    }
}
