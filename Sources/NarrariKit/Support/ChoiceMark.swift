import Foundation

// The radio at the start of a model list row.
public enum ChoiceMark: Sendable, Equatable {
    case chosen
    case available
    // No radio: not downloaded, still loading, not set up, or not a choice in this list.
    case unavailable
}
