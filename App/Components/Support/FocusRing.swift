import SwiftUI

// The system ring is accent coloured, so controls draw this monochrome one and the window turns the system one off.
private struct FocusRing: ViewModifier {
    let isFocused: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: radius + ControlMetrics.focusOffset)
                    .strokeBorder(Color.ink, lineWidth: ControlMetrics.focusRing)
                    .padding(-ControlMetrics.focusOffset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func focusRing(_ isFocused: Bool, radius: CGFloat = Radius.control) -> some View {
        modifier(FocusRing(isFocused: isFocused, radius: radius))
    }
}

// Lets an open editor or confirmation claim Escape, so it cancels that instead of leaving Settings.
struct EscapeTakenKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    func takesEscape(_ isTaken: Bool = true) -> some View {
        preference(key: EscapeTakenKey.self, value: isTaken)
    }
}
