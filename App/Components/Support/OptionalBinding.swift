import SwiftUI

extension Binding {
    // SwiftUI's own Binding(_:) for an optional traps when the value goes nil before the view using it is removed.
    static func unwrapping(_ source: Binding<Value?>) -> Binding<Value>? {
        guard let initial = source.wrappedValue else { return nil }
        return Binding(
            get: { source.wrappedValue ?? initial },
            set: { if source.wrappedValue != nil { source.wrappedValue = $0 } }
        )
    }
}
