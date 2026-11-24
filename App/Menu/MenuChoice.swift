import NarrariKit
import SwiftUI

// A panel row with the current choice at its right; with a choice to make, Return or a click opens the list in place.
struct MenuChoiceRow<Options: View>: View {
    let item: MenuPanelItem
    let title: String
    let value: String
    let isChoice: Bool
    let isOpen: Bool
    let listName: String
    let context: MenuContext
    @ViewBuilder let options: Options

    var body: some View {
        VStack(spacing: 0) {
            if isChoice {
                Button {
                    context.activate(item)
                } label: {
                    ChoiceLine(title: title, value: value, isChoice: true)
                }
                .buttonStyle(MenuRowStyle(
                    isHighlighted: context.isHighlighted(item), isPressed: context.isPressed(item), height: MenuPanelMetrics.modeHeight
                ))
                .menuItem(item, in: context)
                .accessibilityLabel(title)
                .accessibilityValue(value)
                .accessibilityHint(isOpen ? "Hides the \(listName)" : "Shows the \(listName)")
                if isOpen {
                    VStack(spacing: 0) { options }
                        .padding(MenuPanelMetrics.modeListPadding)
                }
            } else {
                ChoiceLine(title: title, value: value, isChoice: false)
                    .padding(.horizontal, MenuPanelMetrics.rowPadding)
                    .frame(height: MenuPanelMetrics.modeHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title), \(value)")
            }
        }
    }
}

struct MenuChoiceOption: View {
    let item: MenuPanelItem
    let title: String
    let isCurrent: Bool
    var tag: String?
    let context: MenuContext

    var body: some View {
        Button {
            context.activate(item)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "checkmark")
                    .font(.system(size: MenuPanelMetrics.checkSymbol, weight: .medium))
                    .padding(.leading, MenuPanelMetrics.checkInset)
                    .frame(width: MenuPanelMetrics.checkColumn, alignment: .leading)
                    .opacity(isCurrent ? 1 : 0)
                Text(title)
                    .truncationMode(.middle)
                if let tag {
                    Spacer(minLength: MenuPanelMetrics.rowGap)
                    Text(tag)
                        .font(Typeface.labelMedium)
                        .foregroundStyle(Color.panelMuted)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(MenuRowStyle(isHighlighted: context.isHighlighted(item), isPressed: context.isPressed(item)))
        .menuItem(item, in: context)
        .accessibilityLabel(title)
        .accessibilityValue(tag ?? "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

private struct ChoiceLine: View {
    let title: String
    let value: String
    let isChoice: Bool

    var body: some View {
        HStack(spacing: MenuPanelMetrics.rowGap) {
            Text(title)
                .font(Typeface.body)
                .foregroundStyle(Color.panelMuted)
                .fixedSize()
            Spacer(minLength: MenuPanelMetrics.rowGap)
            HStack(spacing: MenuPanelMetrics.modeValueGap) {
                Text(value)
                    .font(Typeface.bodyMedium)
                    .truncationMode(.middle)
                if isChoice {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: MenuPanelMetrics.modeSymbol))
                        .imageScale(.small)
                }
            }
            .foregroundStyle(Color.ink)
        }
        .lineLimit(1)
    }
}
