import Foundation

// What the empty dictations page says: how to dictate once the speech model is ready, until then how far it has come.
public struct EmptyHistory: Equatable, Sendable {
    public let said: String
    public let heard: String

    public init(model: ModelState, hotkey: String, kept: String) {
        let then = "hold \(hotkey) anywhere and speak."
        switch model {
        case .ready:
            said = "Hold \(hotkey) anywhere and speak."
            heard = "The text lands in the app you are typing in, and a copy is kept here \(kept)."
        case .preparing(let fraction, let isDownloading):
            said = isDownloading ? "The speech model is downloading." : "The speech model is loading."
            heard = (fraction > 0 ? "\(MetricText.percent(min(fraction, 1))). " : "") + "When it is ready, \(then)"
        case .missing:
            said = "The speech model is loading."
            heard = "When it is ready, \(then)"
        case .failed:
            said = "The speech model could not load."
            heard = "Download it again in Settings, Speech."
        }
    }
}
