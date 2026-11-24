import SwiftUI

struct TextButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case destructive
    }

    var kind = Kind.secondary

    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == TextButtonStyle {
    static var primary: TextButtonStyle { TextButtonStyle(kind: .primary) }
    static var secondary: TextButtonStyle { TextButtonStyle(kind: .secondary) }
    static var destructive: TextButtonStyle { TextButtonStyle(kind: .destructive) }
}

private struct TextButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: TextButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control)
        configuration.label
            .font(kind == .primary ? Typeface.primaryButton : Typeface.button)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, ControlMetrics.buttonPadding)
            .frame(height: ControlMetrics.buttonHeight)
            .background(kind == .primary ? Color.ink : Color.surface, in: shape)
            .overlay(shape.strokeBorder(kind == .primary ? Color.ink : Color.controlEdge, lineWidth: ControlMetrics.edge))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? ControlMetrics.pressedOpacity : 1) : ControlMetrics.disabledOpacity)
            .focusRing(isFocused)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .onInk
        case .secondary: .ink
        case .destructive: .errorInk
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control)
        let isActive = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .font(.system(size: Symbol.window))
            .foregroundStyle(isActive ? Color.ink : Color.ink2)
            .frame(width: ControlMetrics.iconButton, height: ControlMetrics.iconButton)
            .background(isActive ? (configuration.isPressed ? Color.pressedFill : Color.selectionFill) : .clear, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : ControlMetrics.disabledOpacity)
            .focusRing(isFocused)
            .onHover { isHovered = $0 }
    }
}

// Full-width rows in the sidebar: a Selection fill when chosen or hovered, never an accent.
struct RowButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control)
        configuration.label
            .font(isSelected ? Typeface.bodyStrong : Typeface.body)
            .foregroundStyle(Color.ink)
            .padding(.horizontal, Space.s8)
            .frame(maxWidth: .infinity, minHeight: ControlMetrics.navRowHeight, maxHeight: ControlMetrics.navRowHeight, alignment: .leading)
            .background(isSelected || (isHovered && isEnabled) ? Color.selectionFill : .clear, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : ControlMetrics.disabledOpacity)
            .focusRing(isFocused)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
