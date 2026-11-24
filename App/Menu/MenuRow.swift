import NarrariKit
import SwiftUI

// What every part of the panel needs: the model, the row the keyboard is pressing, and what a click does.
@MainActor
struct MenuContext {
    let model: MenuPanel
    let press: MenuPress
    let activate: (MenuPanelItem) -> Void

    func isHighlighted(_ item: MenuPanelItem) -> Bool { model.highlighted == item }
    func isPressed(_ item: MenuPanelItem) -> Bool { press.item == item }
}

// Return shows the press on the highlighted row for a beat before it acts, as a click would.
@MainActor
@Observable
final class MenuPress {
    var item: MenuPanelItem?
}

struct MenuRow: View {
    let item: MenuPanelItem
    let title: String
    var isEnabled = true
    var reason: String?
    let context: MenuContext

    var body: some View {
        Button {
            context.activate(item)
        } label: {
            HStack(spacing: MenuPanelMetrics.rowGap) {
                Text(title)
                Spacer(minLength: MenuPanelMetrics.rowGap)
                if let shortcut = context.model.shortcut(for: item) {
                    Text(shortcut)
                        .monospacedDigit()
                        .opacity(MenuPanelMetrics.shortcutOpacity)
                }
            }
        }
        .buttonStyle(MenuRowStyle(isHighlighted: context.isHighlighted(item), isPressed: context.isPressed(item)))
        .disabled(!isEnabled)
        .menuItem(item, in: context)
        .accessibilityLabel(title)
        .accessibilityHint(reason.map { "Unavailable: \($0)" } ?? "")
    }
}

struct MenuRowStyle: ButtonStyle {
    let isHighlighted: Bool
    let isPressed: Bool
    var height = MenuPanelMetrics.rowHeight

    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration, isHighlighted: isHighlighted, isPressed: isPressed || configuration.isPressed, height: height)
    }
}

private struct MenuRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isHighlighted: Bool
    let isPressed: Bool
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MenuPanelMetrics.rowRadius, style: .continuous)
        configuration.label
            .font(Typeface.body)
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .padding(.horizontal, MenuPanelMetrics.rowPadding)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(isHighlighted && isEnabled ? Color.panelHover : .clear, in: shape)
            .colorMultiply(isPressed && isEnabled ? Color(white: MenuPanelMetrics.pressedMultiply) : .white)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : MenuPanelMetrics.disabledOpacity)
    }
}

struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.panelRule)
            .frame(height: ControlMetrics.edge)
            .padding(MenuPanelMetrics.separatorPadding)
            .accessibilityHidden(true)
    }
}

extension View {
    // The panel moves its own highlight with the keyboard, so SwiftUI focus stays out of it whatever the
    // system's keyboard navigation setting; the pointer moves the same highlight.
    func menuItem(_ item: MenuPanelItem, in context: MenuContext) -> some View {
        focusable(false)
            .focusEffectDisabled()
            .onHover { isInside in
                if isInside { context.model.highlight(item) }
            }
    }
}
