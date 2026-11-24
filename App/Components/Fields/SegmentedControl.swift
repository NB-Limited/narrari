import SwiftUI

// Two or more equal segments on a Selection track; the chosen one is a Raised plate, lighter than the track in both themes. A segment can carry a small
// mark, such as the side that holds the model in use, so that stays visible from the other side.
struct SegmentedControl<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let segments: [(value: Value, title: String)]
    var marked: Value?
    var markLabel = ""
    var segmentWidth = SettingsGrid.segmentWidth

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                let isMarked = segment.value == marked
                Button { selection = segment.value } label: {
                    HStack(spacing: ControlMetrics.innerGap) {
                        Text(segment.title)
                        if isMarked {
                            Circle()
                                .frame(width: SettingsGrid.segmentMark, height: SettingsGrid.segmentMark)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(SegmentStyle(isSelected: segment.value == selection, width: segmentWidth))
                .accessibilityLabel(segment.title)
                .accessibilityValue(isMarked ? markLabel : "")
                .accessibilityAddTraits(segment.value == selection ? .isSelected : [])
            }
        }
        .padding(SettingsGrid.segmentInset)
        .background(Color.selectionFill, in: RoundedRectangle(cornerRadius: SettingsGrid.segmentRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct SegmentStyle: ButtonStyle {
    let isSelected: Bool
    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, isSelected: isSelected, width: width)
    }
}

private struct SegmentBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let width: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let radius = SettingsGrid.segmentRadius - SettingsGrid.segmentInset
        let shape = RoundedRectangle(cornerRadius: radius)
        configuration.label
            .font(isSelected ? Typeface.bodyMedium : Typeface.body)
            .foregroundStyle(isSelected || (isHovered && isEnabled) ? Color.ink : Color.ink2)
            .lineLimit(1)
            .frame(width: width, height: SettingsGrid.segmentHeight - 2 * SettingsGrid.segmentInset)
            .background {
                if isSelected {
                    RaisedPlate(radius: radius, edge: ControlMetrics.hairline)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? ControlMetrics.pressedOpacity : 1) : ControlMetrics.disabledOpacity)
            .focusRing(isFocused, radius: radius)
            .onHover { isHovered = $0 }
    }
}

// The chosen thing lifted off its ground: a light fill, a RaisedEdge and the card drop.
struct RaisedPlate: View {
    let radius: CGFloat
    var fill = Color.raised
    var edge = SettingsGrid.chosenEdge

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        shape
            .fill(fill)
            .shadow(color: .cardShadow, radius: Shadow.card.radius, y: Shadow.card.y)
            .overlay(shape.strokeBorder(Color.raisedEdge, lineWidth: edge))
    }
}
