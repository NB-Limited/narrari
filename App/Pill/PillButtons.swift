import SwiftUI

// A 26 pt circle with a symbol in PillText, on the pill surfaces only.
struct PillIconButton: View {
    let symbol: String
    let label: String
    var size = MeetingMetrics.iconButtonSymbol
    var ink = Color.pillText
    var hoverWash = MeetingMetrics.hoverWash
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size))
        }
        .buttonStyle(PillIconButtonStyle(ink: ink, hoverWash: hoverWash))
        .accessibilityLabel(label)
        .iconLabel(label, tracksPointerAlways: true)
    }
}

private struct PillIconButtonStyle: ButtonStyle {
    let ink: Color
    let hoverWash: Double

    func makeBody(configuration: Configuration) -> some View {
        PillIconButtonBody(configuration: configuration, ink: ink, hoverWash: hoverWash)
    }
}

private struct PillIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let ink: Color
    let hoverWash: Double
    @State private var isHovered = false

    var body: some View {
        let wash = configuration.isPressed ? MeetingMetrics.pressedWash : isHovered ? hoverWash : 0
        configuration.label
            .foregroundStyle(isHovered ? Color.pillText : ink)
            .frame(width: MeetingMetrics.button, height: MeetingMetrics.button)
            .background(Color.white.opacity(wash), in: Circle())
            .contentShape(Circle())
            .background(PointerArea { isHovered = $0 })
    }
}

// Filled for the action the surface asks for (Start, Keep recording), outline for Stop.
struct PillTextButton: View {
    let title: String
    var isFilled = true
    var label: String?
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PillTextButtonStyle(isFilled: isFilled))
            .accessibilityLabel(label ?? title)
    }
}

private struct PillTextButtonStyle: ButtonStyle {
    let isFilled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(Typeface.pill)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isFilled ? Color.pillFill : Color.pillText)
            .padding(.horizontal, MeetingMetrics.buttonPadding)
            .frame(height: MeetingMetrics.button)
            .background(isFilled ? Color.pillText : .clear, in: shape)
            .overlay {
                if !isFilled { shape.strokeBorder(Color.pillText.opacity(MeetingMetrics.outlineEdge), lineWidth: ControlMetrics.edge) }
            }
            .opacity(configuration.isPressed ? MeetingMetrics.pressedOpacity : 1)
            .contentShape(shape)
    }
}
