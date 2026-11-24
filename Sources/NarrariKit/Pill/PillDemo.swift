import Foundation

// The loop the Recorder look preview plays: listening while invented words arrive, cleaning up, done, a pause.
public enum PillDemo {
    public struct Frame: Sendable, Equatable {
        public let state: PillState?
        public let isListening: Bool
        public let seconds: Int
        public let level: Float
    }

    public static let words = ["Thursday", "at", "ten", "works."]
    public static let period = 7.6
    public static let step: Duration = .milliseconds(50)

    private static let firstWord = 0.5
    private static let wordStep = 0.45
    private static let release = 3.8
    private static let done = 5.4
    private static let gone = 6.1

    // Reduce Motion: one listening frame with every word heard.
    public static func still(showsWords: Bool) -> Frame {
        Frame(
            state: PillState(capsule: .recording(slot: nil), caption: showsWords ? words.joined(separator: " ") : nil),
            isListening: true, seconds: 3, level: 0.5
        )
    }

    public static func frame(at time: Double, showsWords: Bool) -> Frame {
        let time = time.truncatingRemainder(dividingBy: period)
        let heard = words.prefix(max(0, min(words.count, Int((time - firstWord) / wordStep) + 1)))
        let caption = showsWords && time >= firstWord && time < done ? heard.joined(separator: " ") : nil
        let seconds = Int(min(time, release))
        switch time {
        case ..<release:
            return Frame(state: PillState(capsule: .recording(slot: nil), caption: caption), isListening: true, seconds: seconds, level: level(at: time))
        case ..<done:
            return Frame(state: PillState(capsule: .working(.cleaning), caption: caption), isListening: false, seconds: seconds, level: 0)
        case ..<gone:
            return Frame(state: PillState(capsule: .done), isListening: false, seconds: seconds, level: 0)
        default:
            return Frame(state: nil, isListening: false, seconds: 0, level: 0)
        }
    }

    // Syllable-like bursts under a slower phrase swell, so the bars move the way speech moves them.
    private static func level(at time: Double) -> Float {
        let syllables = abs(sin(time * 7.3)) * 0.7 + 0.3
        let phrase = 0.55 + 0.45 * sin(time * 1.9 + 0.6)
        return Float(min(1, 0.12 + 0.6 * syllables * phrase))
    }
}
