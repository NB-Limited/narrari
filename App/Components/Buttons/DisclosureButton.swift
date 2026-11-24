import NarrariKit
import SwiftUI

// A quiet "Details" style toggle: a chevron that turns down when open, the title beside it.
struct DisclosureButton: View {
    let title: String
    @Binding var isOpen: Bool

    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.s4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: Symbol.disclosure, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text(title)
            }
        }
        .buttonStyle(DisclosureButtonStyle())
        .onKeyPress(.return) {
            toggle()
            return .handled
        }
        .accessibilityLabel(title)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : Motion.fade) { isOpen.toggle() }
    }
}

private struct DisclosureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureButtonBody(configuration: configuration)
    }
}

private struct DisclosureButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control)
        configuration.label
            .font(Typeface.small)
            .foregroundStyle(isHovered || configuration.isPressed ? Color.ink : Color.muted)
            .padding(.horizontal, ControlMetrics.innerGap)
            .frame(height: ControlMetrics.buttonHeight)
            .background(configuration.isPressed ? Color.pressedFill : isHovered ? Color.selectionFill : .clear, in: shape)
            .contentShape(shape)
            .focusRing(isFocused)
            .onHover { isHovered = $0 }
    }
}
