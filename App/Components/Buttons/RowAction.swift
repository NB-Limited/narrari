import SwiftUI

// A whole list row as one target: a Selection plate on hover, the focus ring around it, Space or Return acts.
// Buttons inside keep their own clicks; like a button, it takes focus only with keyboard navigation on.
private struct RowAction: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(isHovered && isEnabled ? Color.selectionFill : .clear)
                    .padding(.horizontal, -SettingsGrid.plateOutset)
                    .padding(.vertical, SettingsGrid.plateInset)
                    .focusRing(isFocused && isEnabled)
            }
            .onHover { isHovered = $0 }
            .onTapGesture { if isEnabled { action() } }
            .focusable(isEnabled, interactions: .activate)
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.space, .return]) { _ in
                guard isEnabled else { return .ignored }
                action()
                return .handled
            }
    }
}

extension View {
    func rowAction(isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(RowAction(isEnabled: isEnabled, action: action))
    }
}
