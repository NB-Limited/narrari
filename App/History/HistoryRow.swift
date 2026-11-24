import NarrariKit
import SwiftUI

struct HistoryRow: View {
    let entry: HistoryEntry
    let source: String
    let isSelected: Bool
    var isPending = false
    let onSelect: () -> Void

    @State private var isHovered = false

    private static let pendingText = "Transcribing the file"

    private var summary: String {
        if isPending { return Self.pendingText }
        return entry.finalText.isEmpty ? (entry.outcomeNote ?? "No text") : entry.finalText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.itemGap) {
            HStack {
                Text("\(EntryFormat.time(entry))  \(source)")
                    .lineLimit(1)
                Spacer(minLength: Space.s8)
                if !isPending {
                    Text(EntryFormat.length(entry))
                }
            }
            .font(Typeface.meta)
            .foregroundStyle(Color.muted)

            Text(summary)
                .font(Typeface.body)
                .lineSpacing(Typeface.listLineSpacing)
                .foregroundStyle(entry.finalText.isEmpty ? Color.muted : Color.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isCleanupSkipped {
                Label {
                    Text("Clean-up skipped").font(Typeface.meta)
                } icon: {
                    Image(systemName: "exclamationmark.circle").font(.system(size: Symbol.note))
                }
                .labelStyle(TightLabelStyle())
                .foregroundStyle(Color.ink2)
                    .padding(.top, Space.s2)
            }
        }
        .padding(.vertical, WindowMetrics.itemPadding)
        .padding(.horizontal, Space.s8)
        .background(isSelected || isHovered ? Color.selectionFill : .clear, in: RoundedRectangle(cornerRadius: Radius.listItem))
        .contentShape(RoundedRectangle(cornerRadius: Radius.listItem))
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPending ? "\(source), \(Self.pendingText)" : EntryFormat.spokenSummary(entry, source: source))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
    }
}
