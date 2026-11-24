import NarrariKit
import SwiftUI

// The last dictation set as a printed card; the whole card is the control, Return or a click copies it.
struct LastDictationCard: View {
    let last: LastDictation
    let context: MenuContext

    var body: some View {
        let isHighlighted = context.isHighlighted(.lastDictation)
        Button {
            context.activate(.lastDictation)
        } label: {
            VStack(alignment: .leading, spacing: MenuPanelMetrics.footerGap) {
                ClampedText(text: last.text)
                HStack(spacing: MenuPanelMetrics.rowGap) {
                    Text(last.meta)
                        .font(Typeface.cardMeta)
                        .foregroundStyle(Color.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    CopyChip(isCopied: context.model.isCopied, isHighlighted: isHighlighted)
                }
            }
        }
        .buttonStyle(CardStyle(isHighlighted: isHighlighted, isPressed: context.isPressed(.lastDictation)))
        .menuItem(.lastDictation, in: context)
        .accessibilityLabel("Last dictation, \(last.meta)")
        .accessibilityValue(last.text)
        .accessibilityHint(context.model.isCopied ? "Copied" : "Copies it")
    }
}

struct EmptyDictationCard: View {
    let hotkey: String

    var body: some View {
        VStack(alignment: .leading, spacing: MenuPanelMetrics.footerGap) {
            Text("Hold \(hotkey) anywhere and speak.")
                .font(Typeface.heard)
                .lineSpacing(Typeface.cardLineSpacing)
                .padding(.vertical, Typeface.cardLineSpacing / 2)
            Text("The text lands in the app you are typing in.")
                .font(Typeface.cardMeta)
                .foregroundStyle(Color.muted)
        }
        .foregroundStyle(Color.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardSurface(isHighlighted: false))
        .accessibilityElement(children: .combine)
    }
}

private struct CardStyle: ButtonStyle {
    let isHighlighted: Bool
    let isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CardSurface(isHighlighted: isHighlighted))
            .scaleEffect(isPressed || configuration.isPressed ? MenuPanelMetrics.cardPressedScale : 1)
    }
}

// Paper on the panel: an edge and a soft drop, swapped for a ring in the text colour when highlighted.
private struct CardSurface: ViewModifier {
    let isHighlighted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MenuPanelMetrics.cardRadius, style: .continuous)
        let ring = isHighlighted ? MenuPanelMetrics.cardRing : ControlMetrics.hairline
        content
            .padding(MenuPanelMetrics.cardPadding)
            .background {
                shape
                    .fill(Color.surface)
                    .shadow(color: isHighlighted ? .clear : .cardShadow, radius: Shadow.card.radius, y: Shadow.card.y)
            }
            .overlay {
                RoundedRectangle(cornerRadius: MenuPanelMetrics.cardRadius + ring / 2, style: .continuous)
                    .stroke(isHighlighted ? Color.ink : .cardEdge, lineWidth: ring)
                    .padding(-ring / 2)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
    }
}

private struct CopyChip: View {
    let isCopied: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: MenuPanelMetrics.copyGap) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: MenuPanelMetrics.copySymbol))
                .imageScale(.small)
            Text(isCopied ? "Copied" : "Copy")
            Text("↩")
                .font(Typeface.labelMedium)
                .opacity(MenuPanelMetrics.returnOpacity)
        }
        .font(Typeface.smallMedium)
        .foregroundStyle(isHighlighted ? Color.onInk : .ink)
        .padding(MenuPanelMetrics.copyPadding)
        .frame(height: MenuPanelMetrics.copyHeight)
        .background(isHighlighted ? Color.ink : .cardButton, in: RoundedRectangle(cornerRadius: MenuPanelMetrics.copyRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

// Clamped to the card's line count; when it runs longer, the last line fades out at its end instead of an ellipsis.
private struct ClampedText: View {
    let text: String
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        let lines = CGFloat(MenuPanelMetrics.cardLines)
        let limit = lines * Typeface.cardLineBox + (lines - 1) * Typeface.cardLineSpacing
        let isClamped = fullHeight > limit + 1
        Text(text)
            .font(Typeface.heard)
            .lineSpacing(Typeface.cardLineSpacing)
            .foregroundStyle(Color.ink)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            .frame(maxHeight: limit, alignment: .top)
            .clipped()
            .mask {
                if isClamped {
                    VStack(spacing: 0) {
                        Rectangle()
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: MenuPanelMetrics.cardFade)
                        }
                        .frame(height: Typeface.cardLineBox)
                    }
                } else {
                    Rectangle()
                }
            }
            .padding(.vertical, Typeface.cardLineSpacing / 2)
    }
}
