import NarrariKit
import SwiftUI

// The Colour look's presets as round swatches; the chosen one carries a check in PillFill, the pair the pill itself shows.
struct SwatchRow: View {
    let label: String
    @Binding var selection: PillColour
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: ControlMetrics.swatchGap) {
            ForEach(PillColour.allCases, id: \.self) { colour in
                Button { selection = colour } label: {
                    Circle().fill(colour.color(highContrast: contrast == .increased))
                }
                .buttonStyle(SwatchStyle(isSelected: colour == selection))
                .accessibilityLabel(colour.name)
                .accessibilityAddTraits(colour == selection ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct SwatchStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SwatchBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct SwatchBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .overlay { Circle().strokeBorder(Color.raisedEdge, lineWidth: ControlMetrics.hairline) }
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: ControlMetrics.swatchCheck, weight: .bold))
                        .foregroundStyle(Color.pillFill)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: ControlMetrics.swatch, height: ControlMetrics.swatch)
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? ControlMetrics.pressedOpacity : 1) : ControlMetrics.disabledOpacity)
            .focusRing(isFocused, radius: ControlMetrics.swatch / 2)
    }
}
