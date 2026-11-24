import Foundation

// The two halves of a model list in settings: the models that run on this Mac, and the outside service.
public enum ModelSide: Sendable, Equatable, CaseIterable {
    case thisMac
    case outside
}
