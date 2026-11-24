import NarrariKit
import SwiftUI

// A failed meeting, or work that ended while the panel was closed: what it was, Failed or Done, and a click opens it.
struct MenuNoteRow: View {
    let note: MenuNote
    let context: MenuContext

    var body: some View {
        let isFailed = note.state.problem != nil
        Button {
            context.activate(.note(note.target))
        } label: {
            HStack(spacing: MenuPanelMetrics.warningGap) {
                Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: MenuPanelMetrics.warningSymbol))
                    .foregroundStyle(isFailed ? Color.errorInk : Color.ink2)
                Text(note.title).truncationMode(.middle)
                Spacer(minLength: MenuPanelMetrics.rowGap)
                Text(note.state.brief)
                    .font(Typeface.labelMedium)
                    .foregroundStyle(isFailed ? Color.errorInk : Color.panelMuted)
            }
        }
        .buttonStyle(MenuRowStyle(isHighlighted: context.isHighlighted(.note(note.target)), isPressed: context.isPressed(.note(note.target))))
        .menuItem(.note(note.target), in: context)
        .accessibilityLabel("\(note.title), \(note.state.label)")
    }
}
